BEGIN;

-- Runtime roles are provisioned by the checksummed control-plane phase.  This
-- product migration may grant only after proving that every principal arrives
-- inert: exact attributes, no membership, no ownership, and no direct ACL in
-- this database or on shared objects.
DO $r6e_role_precondition$
DECLARE
  v_expected record;
  v_role_oid oid;
BEGIN
  FOR v_expected IN
    SELECT * FROM (VALUES
      ('gurine_economics_writer',false,-1),
      ('gurine_payment_writer',false,-1),
      ('gurine_billing_gateway',true,8),
      ('gurine_economics_importer',true,4)
    ) AS expected(role_name,can_login,connection_limit)
  LOOP
    SELECT oid INTO v_role_oid
    FROM pg_roles
    WHERE rolname=v_expected.role_name;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'R6E_RUNTIME_ROLE_MISSING'
        USING ERRCODE='42501',DETAIL=v_expected.role_name;
    END IF;
    IF EXISTS (
      SELECT 1
      FROM pg_roles AS role_state
      WHERE role_state.oid=v_role_oid
        AND (role_state.rolsuper
          OR role_state.rolinherit
          OR role_state.rolcreaterole
          OR role_state.rolcreatedb
          OR role_state.rolreplication
          OR role_state.rolbypassrls
          OR role_state.rolcanlogin IS DISTINCT FROM v_expected.can_login
          OR role_state.rolconnlimit IS DISTINCT FROM
            v_expected.connection_limit
          OR role_state.rolvaliduntil IS NOT NULL
          OR role_state.rolconfig IS NOT NULL)
    ) THEN
      RAISE EXCEPTION 'R6E_RUNTIME_ROLE_PRECONDITION_FAILED'
        USING ERRCODE='42501';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM pg_auth_members AS membership
      WHERE membership.roleid=v_role_oid OR membership.member=v_role_oid
    ) THEN
      RAISE EXCEPTION 'R6E_RUNTIME_ROLE_MEMBERSHIP_FORBIDDEN'
        USING ERRCODE='42501';
    END IF;
    IF EXISTS (
      SELECT 1 FROM pg_db_role_setting AS role_setting
      WHERE role_setting.setrole=v_role_oid
    ) THEN
      RAISE EXCEPTION 'R6E_RUNTIME_ROLE_SETTING_FORBIDDEN'
        USING ERRCODE='42501';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM pg_shdepend AS dependency
      WHERE dependency.refclassid='pg_authid'::regclass
        AND dependency.refobjid=v_role_oid
        AND dependency.deptype IN ('a','o')
    ) THEN
      RAISE EXCEPTION 'R6E_RUNTIME_ROLE_AUTHORITY_FORBIDDEN'
        USING ERRCODE='42501';
    END IF;
  END LOOP;
END
$r6e_role_precondition$;

GRANT USAGE ON SCHEMA ops TO
  gurine_billing_gateway,gurine_economics_importer;
REVOKE CREATE ON SCHEMA ops,extensions FROM
  gurine_economics_writer,gurine_payment_writer,gurine_billing_gateway,
  gurine_economics_importer;

INSERT INTO ops.capabilities(code,description,risk_level)
VALUES ('economics.import','승인된 경제 원장 import 실행','CRITICAL')
ON CONFLICT (code) DO UPDATE SET
  description=EXCLUDED.description,
  risk_level=EXCLUDED.risk_level;

-- R6e adds exactly two event kinds.  The existing funding publication event
-- is narrowed to its current eleven-field contract so the projector can bind
-- the immutable revision rather than infer it from private tables.
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES
(
  'donation.fact_recorded.v1','DOMAIN',1,true,
  'payloads/donation_fact_recorded_v1.schema.json',
  $schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/donation.fact_recorded.v1.schema.json","type":"object","additionalProperties":false,"required":["donationFactId","donationFactDigest","chargeAttemptId","chargeAttemptDigest","providerFetchDigest","occurredAt"],"properties":{"donationFactId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},"donationFactDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"chargeAttemptId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},"chargeAttemptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"providerFetchDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"occurredAt":{"type":"string","format":"date-time"}}}$schema$::jsonb
),
(
  'notification.payment_review_requested.v1','DOMAIN',1,true,
  'payloads/notification_payment_review_requested_v1.schema.json',
  $schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/notification.payment_review_requested.v1.schema.json","type":"object","additionalProperties":false,"required":["reviewTaskId","reviewTaskVersion","reviewTaskDigest","sourceKind","sourceReceiptId","sourceReceiptDigest","occurredAt"],"properties":{"reviewTaskId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},"reviewTaskVersion":{"type":"integer","minimum":1},"reviewTaskDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"sourceKind":{"type":"string","enum":["DONATION_PAYMENT_FAILURE","SIGNED_COLLECTION_FAILURE"]},"sourceReceiptId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},"sourceReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"occurredAt":{"type":"string","format":"date-time"}}}$schema$::jsonb
)
ON CONFLICT (event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;

-- These two rows are forward overrides of event kinds owned by migration 0030.
-- They remain separate from the exact two R6e-owned events above.  A complete
-- closed upsert makes the override auditable; no partial jsonb_set can retain
-- an unknown prior field.
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES
(
  'governance.funding_disclosure_published.v1','DOMAIN',1,true,
  'payloads/governance_funding_disclosure_published_v1.schema.json',
  $schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/governance.funding_disclosure_published.v1.schema.json","type":"object","additionalProperties":false,"required":["disclosureId","revisionId","revision","revisionDigest","snapshotBatchId","snapshotDigest","concentrationBand","entrySetDigest","priorRevision","effectiveAt","receiptDigest"],"properties":{"concentrationBand":{"type":"string","minLength":1,"maxLength":10000},"disclosureId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},"effectiveAt":{"type":"string","format":"date-time"},"entrySetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"priorRevision":{"anyOf":[{"type":"integer","minimum":1},{"type":"null"}]},"receiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"revision":{"type":"integer","minimum":1},"revisionDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"revisionId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},"snapshotBatchId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},"snapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}}$schema$::jsonb
),
(
  'action.proposal_created.v1','DOMAIN',1,true,
  'payloads/action_proposal_created_v1.schema.json',
  $schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/action.proposal_created.v1.schema.json","type":"object","additionalProperties":false,"required":["proposalId","version","actionKind","contentDigest","targetId","targetVersion","expiresAt"],"properties":{"actionKind":{"type":"string","enum":["HYPOTHESIS","CLAIM","TASK","COMPARABLE","COMMUNICATION","PUBLICATION","RETRACTION","RULE_ACTIVATION","ROLE_GRANT","KILL_SWITCH","COMMUNICATION_AUTHORIZATION","ASSET_RIGHTS_DECISION","RETENTION_SCHEDULE","FUNDING_DISCLOSURE","CAPABILITY_ACTIVATION","RESPONSE_POLICY_CALENDAR","COMMERCIAL_CONTROL","PROVIDER_CONTROL","ECONOMICS_IMPORT"]},"contentDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"expiresAt":{"type":"string","format":"date-time"},"proposalId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},"targetId":{"type":"string","minLength":1,"maxLength":10000},"targetVersion":{"type":"integer","minimum":0},"version":{"type":"integer","minimum":0}}}$schema$::jsonb
)
ON CONFLICT (event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;

DO $r6e_event_forward_override_validation$
DECLARE
  v_event record;
BEGIN
  FOR v_event IN
    SELECT event_type,id,payload
    FROM ops.outbox
    WHERE event_type IN (
      'governance.funding_disclosure_published.v1',
      'action.proposal_created.v1'
    )
    ORDER BY event_type,id
  LOOP
    PERFORM ops.event_payload_historical_valid_v1(
      v_event.event_type,v_event.payload
    );
  END LOOP;
END
$r6e_event_forward_override_validation$;

CREATE FUNCTION ops.consume_billing_gateway_assertion_jti_v1(
  p_assertion_type text,
  p_jti uuid,
  p_issuer text,
  p_audience text,
  p_expires_at timestamptz,
  p_request_digest char(64)
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $r6e_billing_assertion_replay$
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_billing_gateway'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  RETURN ops.consume_assertion_jti(
    p_assertion_type,p_jti,p_issuer,p_audience,p_expires_at,p_request_digest
  );
END
$r6e_billing_assertion_replay$;
ALTER FUNCTION ops.consume_billing_gateway_assertion_jti_v1(
  text,uuid,text,text,timestamptz,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.consume_billing_gateway_assertion_jti_v1(
  text,uuid,text,text,timestamptz,char(64)
) FROM PUBLIC,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_public_projector,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_economics_importer,gurine_economics_writer,gurine_payment_writer,
  gurine_egress_gateway;
GRANT EXECUTE ON FUNCTION ops.consume_billing_gateway_assertion_jti_v1(
  text,uuid,text,text,timestamptz,char(64)
) TO gurine_billing_gateway;

-- Extend the closed action catalogue.  ECONOMICS_IMPORT is always a private,
-- database-only command and its target is the exact immutable import detail.
ALTER TABLE ops.action_proposals
  DROP CONSTRAINT action_proposals_action_kind_check;
ALTER TABLE ops.action_proposals
  ADD CONSTRAINT action_proposals_action_kind_check CHECK (action_kind IN (
    'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
    'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
    'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
    'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
    'COMMERCIAL_CONTROL','PROVIDER_CONTROL','ECONOMICS_IMPORT'
  ));
ALTER TABLE ops.action_proposals
  DROP CONSTRAINT action_proposals_target_type_check;
ALTER TABLE ops.action_proposals
  ADD CONSTRAINT action_proposals_target_type_check CHECK (target_type IN (
    'CASE','CLAIM','TASK','LINE_ITEM','COMMUNICATION_INTENT','PUBLICATION',
    'RULE_VERSION','USER','KILL_SWITCH','COMMUNICATION_SUBJECT','ASSET',
    'RECORD_CLASS','FUNDING_DISCLOSURE','CAPABILITY','BUSINESS_CALENDAR',
    'BUSINESS_CONTROL_TRIGGER','ECONOMICS_IMPORT'
  ));
ALTER TABLE ops.action_proposal_versions
  DROP CONSTRAINT action_proposal_versions_detail_kind_check;
ALTER TABLE ops.action_proposal_versions
  ADD CONSTRAINT action_proposal_versions_detail_kind_check CHECK (
    action_detail_kind IS NULL OR action_detail_kind IN (
      'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
      'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
      'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
      'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
      'COMMERCIAL_CONTROL','PROVIDER_CONTROL','ECONOMICS_IMPORT'
    )
  );
ALTER TABLE ops.in_flight_effects
  DROP CONSTRAINT in_flight_effects_action_kind_check;
ALTER TABLE ops.in_flight_effects
  ADD CONSTRAINT in_flight_effects_action_kind_check CHECK (
    action_kind IS NULL OR action_kind IN (
      'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
      'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
      'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
      'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
      'COMMERCIAL_CONTROL','PROVIDER_CONTROL','ECONOMICS_IMPORT'
    )
  );
ALTER TABLE ops.execution_authorizations
  DROP CONSTRAINT execution_authorizations_action_kind_check;
ALTER TABLE ops.execution_authorizations
  ADD CONSTRAINT execution_authorizations_action_kind_check CHECK (action_kind IN (
    'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
    'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
    'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
    'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
    'COMMERCIAL_CONTROL','PROVIDER_CONTROL','ECONOMICS_IMPORT'
  ));
ALTER TABLE editorial.conflict_snapshots
  DROP CONSTRAINT conflict_snapshots_action_kind_ck;
ALTER TABLE editorial.conflict_snapshots
  ADD CONSTRAINT conflict_snapshots_action_kind_ck CHECK (
    action_kind IS NULL OR action_kind IN (
      'HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION',
      'RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH',
      'COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE',
      'FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR',
      'COMMERCIAL_CONTROL','PROVIDER_CONTROL','ECONOMICS_IMPORT'
    )
  );

-- The action command arrives through the existing JSON command envelope, but
-- its operation is converted into one of these closed row-valued composites
-- before a draft can be previewed.  No relation name or arbitrary map is part
-- of the approved detail.
CREATE TYPE ops.economics_source_resolution_v1 AS ENUM ('APPEND','EXISTING');

CREATE TYPE ops.economics_acquisition_source_import_v1 AS (
  resolution ops.economics_source_resolution_v1,
  existing_receipt_id uuid,
  existing_receipt_revision bigint,
  existing_receipt_digest char(64),
  append_value ops.acquisition_source_receipt_input_v1,
  evidence_segment_id uuid,
  evidence_segment_digest char(64),
  source_signature_digest char(64),
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_fx_rate_append_v1 AS (
  root_rate_id uuid,
  revision bigint,
  fact_kind ops.fx_fact_kind,
  supersedes_rate_id uuid,
  source_currency char(3),
  target_currency char(3),
  quote_convention text,
  rate numeric(30,12),
  rate_kind ops.fx_rate_kind,
  source_id text,
  source_record_identity_hmac char(64),
  source_record_hmac_key_version text,
  source_priority smallint,
  observed_at timestamptz,
  valid_until timestamptz,
  rate_policy_digest char(64),
  source_receipt_digest char(64),
  signature_digest char(64),
  correction_reason ops.fx_correction_reason,
  approver_id uuid,
  decision_digest char(64),
  expected_record_digest char(64)
);

CREATE TYPE ops.economics_fx_rate_source_import_v1 AS (
  resolution ops.economics_source_resolution_v1,
  existing_rate_id uuid,
  existing_rate_revision bigint,
  existing_rate_digest char(64),
  append_value ops.economics_fx_rate_append_v1,
  evidence_segment_id uuid,
  evidence_segment_digest char(64),
  source_signature_digest char(64),
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_discount_append_v1 AS (
  deployment_id uuid,
  organization_id uuid,
  contract_period_id uuid,
  contract_id uuid,
  sku ops.commercial_sku,
  tariff_version_id uuid,
  tariff_record_digest char(64),
  accounting_timezone text,
  accounting_policy_digest char(64),
  root_discount_id uuid,
  revision bigint,
  state ops.discount_state,
  supersedes_discount_id uuid,
  applies_workspace_base boolean,
  applies_active_contributor_block boolean,
  applies_processing_credit_overage boolean,
  applies_storage_gb_month_overage boolean,
  applies_api_record_unit_overage boolean,
  applies_sla_add_on boolean,
  basis_points integer,
  reason_code ops.discount_reason,
  effective_from date,
  effective_until date,
  required_variable_gross_margin_basis_points integer,
  projected_margin_after_discount_basis_points integer,
  margin_assumption_digest char(64),
  expected_resulting_discount_set_digest char(64),
  undiscounted_p75_revenue_amount numeric(24,6),
  discounted_p75_revenue_amount numeric(24,6),
  p75_variable_cost_amount numeric(24,6),
  cost_evidence_digest char(64),
  margin_formula_digest char(64),
  margin_evidence_as_of timestamptz,
  oversight_reason text,
  oversight_expires_at date,
  oversight_approver_id uuid,
  oversight_decision_digest char(64),
  proposed_by uuid,
  approver_id uuid,
  decision_digest char(64),
  source_receipt_digest char(64),
  signature_digest char(64),
  expected_record_digest char(64)
);

CREATE TYPE ops.economics_discount_source_import_v1 AS (
  resolution ops.economics_source_resolution_v1,
  existing_discount_id uuid,
  existing_discount_revision bigint,
  existing_discount_digest char(64),
  append_value ops.economics_discount_append_v1,
  evidence_segment_id uuid,
  evidence_segment_digest char(64),
  source_signature_digest char(64),
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_qualification_import_v1 AS (
  root_receipt_id uuid,
  revision bigint,
  receipt_effect ops.commercial_qualification_receipt_effect,
  supersedes_receipt_id uuid,
  predecessor_receipt_digest char(64),
  qualification_episode_id uuid,
  deployment_id uuid,
  organization_id uuid,
  sku ops.commercial_sku,
  decision_effective_at timestamptz,
  first_qualified_at timestamptz,
  recurring_job_attested boolean,
  authorized_data_identified boolean,
  authorized_data_feasible boolean,
  economic_buyer_role_bound boolean,
  operational_owner_role_bound boolean,
  independent_reviewer_role_bound boolean,
  source_rights_owner_role_bound boolean,
  incident_support_owner_role_bound boolean,
  pilot_scope_accepted boolean,
  success_metric_accepted boolean,
  budget_authority_accepted boolean,
  support_expectation_accepted boolean,
  trust_terms_accepted boolean,
  role_binding_hmac_key_version text,
  economic_buyer_primary_role_binding_hmac char(64),
  economic_buyer_backup_role_binding_hmac char(64),
  operational_owner_primary_role_binding_hmac char(64),
  operational_owner_backup_role_binding_hmac char(64),
  independent_reviewer_primary_role_binding_hmac char(64),
  independent_reviewer_backup_role_binding_hmac char(64),
  source_rights_owner_primary_role_binding_hmac char(64),
  source_rights_owner_backup_role_binding_hmac char(64),
  incident_support_owner_primary_role_binding_hmac char(64),
  incident_support_owner_backup_role_binding_hmac char(64),
  source_system_id text,
  source_record_identity_hmac char(64),
  acquisition_source_receipt_id uuid,
  acquisition_source_receipt_digest char(64),
  source_signature_digest char(64),
  qualification_policy_version bigint,
  qualification_policy_digest char(64),
  criterion_set_digest char(64),
  role_binding_set_digest char(64),
  evidence_set_digest char(64),
  reason_code ops.commercial_qualification_reason,
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64),
  acquisition_source ops.economics_acquisition_source_import_v1
);

CREATE TYPE ops.economics_cost_period_import_v1 AS (
  period_revision_id uuid,
  supersedes_period_revision_id uuid,
  deployment_id uuid,
  accounting_timezone text,
  accounting_policy_digest char(64),
  period_start date,
  period_end date,
  currency char(3),
  period_version bigint,
  source_set_digest char(64),
  pool_set_digest char(64),
  driver_set_digest char(64),
  correction_set_digest char(64),
  expected_allocation_set_digest char(64),
  expected_captured_cost_count bigint,
  expected_cost_count bigint,
  expected_cost_capture_state text,
  expected_cost_capture_coverage numeric(18,12),
  expected_direct_eligible_amount numeric(24,6),
  expected_direct_allocated_amount numeric(24,6),
  expected_captured_cost_amount numeric(24,6),
  expected_attributed_cost_amount numeric(24,6),
  expected_unallocated_amount numeric(24,6),
  expected_direct_coverage numeric(18,12),
  expected_total_coverage numeric(18,12),
  expected_claim_state text,
  incomplete_reason_set_digest char(64),
  unknown_cost_scope_digest char(64),
  close_receipt_id uuid,
  close_receipt_digest char(64),
  closed_at timestamptz,
  schedule_revision bigint,
  schedule_digest char(64),
  expected_head_id uuid,
  expected_head_version bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_cost_line_import_v1 AS (
  line_sequence bigint,
  allocation_kind text,
  cost_category text,
  source_cost_event_id uuid,
  source_effective_digest char(64),
  source_currency char(3),
  source_amount numeric(24,6),
  fx_rate_fact_id uuid,
  fx_source_ordinal integer,
  reporting_source_amount numeric(24,6),
  target_kind text,
  job_id uuid,
  agent_run_id uuid,
  case_id uuid,
  organization_id uuid,
  outcome_fact_id uuid,
  acquisition_campaign_digest char(64),
  acquisition_source_receipt_id uuid,
  acquisition_source_receipt_digest char(64),
  acquisition_attribution_state ops.acquisition_attribution_state,
  unattributed_acquisition_pool_digest char(64),
  driver_kind text,
  driver_quantity numeric(24,6),
  driver_total_quantity numeric(24,6),
  allocation_ratio numeric(18,12),
  rounding_adjustment numeric(24,6),
  allocated_amount numeric(24,6),
  allocation_rule_version bigint,
  allocation_rule_digest char(64),
  schedule_revision bigint,
  schedule_digest char(64)
);

CREATE TYPE ops.economics_cost_close_import_v1 AS (
  period ops.economics_cost_period_import_v1,
  lines ops.economics_cost_line_import_v1[],
  fx_rates ops.economics_fx_rate_source_import_v1[]
);

CREATE TYPE ops.economics_tariff_import_v1 AS (
  deployment_id uuid,
  sku ops.commercial_sku,
  currency char(3),
  accounting_timezone text,
  accounting_policy_digest char(64),
  effective_from date,
  effective_until date,
  workspace_base_amount numeric(24,6),
  included_active_contributors integer,
  active_contributor_block_size integer,
  active_contributor_block_amount numeric(24,6),
  included_processing_credits numeric(24,6),
  processing_credit_overage_amount numeric(24,6),
  included_storage_gb_month numeric(24,6),
  storage_gb_month_overage_amount numeric(24,6),
  included_api_record_units numeric(24,6),
  api_record_unit_overage_amount numeric(24,6),
  sla_add_on_amount numeric(24,6),
  sla_offer_state ops.sla_offer_state,
  sla_policy_version text,
  sla_policy_digest char(64),
  sla_target_availability_ratio numeric(20,18),
  sla_capability_set_digest char(64),
  sla_exclusion_schedule_digest char(64),
  sla_service_credit_schedule_digest char(64),
  sla_measurement_policy_digest char(64),
  sla_policy_source_receipt_digest char(64),
  sla_policy_signature_digest char(64),
  included_signed_webhook_deliveries bigint,
  included_digest_deliveries bigint,
  expected_required_variable_gross_margin_basis_points integer,
  expected_projected_p75_variable_gross_margin_basis_points integer,
  p75_assumption_digest char(64),
  cost_allocation_period_id uuid,
  cost_allocation_row_kind text,
  cost_allocation_record_digest char(64),
  cost_allocation_set_digest char(64),
  cost_allocation_close_receipt_digest char(64),
  cost_capture_coverage numeric(18,12),
  direct_cost_coverage numeric(18,12),
  total_cost_coverage numeric(18,12),
  p75_revenue_amount numeric(24,6),
  p75_variable_cost_amount numeric(24,6),
  margin_formula_digest char(64),
  margin_evidence_as_of timestamptz,
  margin_exception_reason text,
  margin_exception_expires_at date,
  oversight_approver_id uuid,
  oversight_decision_digest char(64),
  component_set_digest char(64),
  pricing_policy_digest char(64),
  tax_policy_digest char(64),
  proposed_by uuid,
  approver_id uuid,
  decision_digest char(64),
  source_receipt_digest char(64),
  signature_digest char(64),
  expected_cost_head_id uuid,
  expected_cost_head_version bigint,
  expected_cost_head_digest char(64),
  expected_current_tariff_id uuid,
  expected_current_tariff_digest char(64)
);

-- entry_payload, canonical bytes, and entry digest are generated inside the
-- database from this scalar-only composite.  Callers cannot smuggle generic
-- JSON into an approved offer profile.
CREATE TYPE ops.economics_offer_capability_import_v1 AS (
  capability_ordinal smallint,
  capability_code ops.offer_capability_code,
  offer_state ops.offer_capability_state,
  quota_kind ops.offer_quota_kind,
  included_quantity numeric(24,6),
  overage_policy ops.offer_overage_policy,
  overage_unit_price numeric(24,6),
  activation_policy_digest char(64),
  consent_policy_digest char(64),
  cost_policy_digest char(64)
);

CREATE TYPE ops.economics_contract_import_v1 AS (
  deployment_id uuid,
  organization_id uuid,
  contract_id uuid,
  root_contract_period_id uuid,
  revision bigint,
  fact_effect ops.commercial_period_fact_effect,
  supersedes_contract_period_id uuid,
  predecessor_record_digest char(64),
  contract_reference_hmac char(64),
  contract_reference_hmac_key_version text,
  period_start date,
  period_end date,
  sku ops.commercial_sku,
  tariff_version_id uuid,
  tariff_record_digest char(64),
  qualification_receipt_id uuid,
  qualification_episode_id uuid,
  qualification_receipt_digest char(64),
  offer_contract_binding_digest char(64),
  offer_profile_id uuid,
  offer_profile_version bigint,
  offer_profile_digest char(64),
  offer_capability_set_digest char(64),
  offer_quota_set_digest char(64),
  offer_overage_policy_set_digest char(64),
  offer_service_credit_policy_digest char(64),
  offer_effective_from timestamptz,
  offer_effective_until timestamptz,
  offer_source_receipt_digest char(64),
  offer_signature_digest char(64),
  currency char(3),
  accounting_timezone text,
  accounting_policy_digest char(64),
  binding_committed_amount numeric(24,6),
  commitment_policy_digest char(64),
  status ops.commercial_contract_status,
  stage ops.tariff_stage,
  provisioning_state ops.commercial_provisioning_state,
  sla_add_on_selected boolean,
  sla_selection_state ops.sla_selection_state,
  sla_policy_version text,
  sla_policy_digest char(64),
  sla_target_availability_ratio numeric(20,18),
  sla_capability_set_digest char(64),
  sla_exclusion_schedule_digest char(64),
  sla_service_credit_schedule_digest char(64),
  sla_measurement_policy_digest char(64),
  signed_at timestamptz,
  provisioned_at timestamptz,
  state_effective_at timestamptz,
  deployment_configuration_digest char(64),
  authority_reference_digest char(64),
  approver_id uuid,
  decision_digest char(64),
  source_receipt_digest char(64),
  signature_digest char(64),
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64),
  collection_failure_task_id uuid,
  collection_failure_task_version bigint,
  collection_failure_task_digest char(64),
  capabilities ops.economics_offer_capability_import_v1[]
);

CREATE TYPE ops.economics_usage_receipt_import_v1 AS (
  root_receipt_id uuid,
  receipt_version bigint,
  receipt_effect ops.usage_receipt_effect,
  supersedes_receipt_id uuid,
  predecessor_receipt_digest char(64),
  deployment_id uuid,
  organization_id uuid,
  contract_period_id uuid,
  contract_id uuid,
  tariff_version_id uuid,
  sku ops.commercial_sku,
  accounting_timezone text,
  accounting_policy_digest char(64),
  period_start date,
  period_end date,
  measurement_window_digest char(64),
  receipt_kind ops.usage_receipt_kind,
  meter_kind ops.usage_meter_kind,
  unit ops.usage_unit,
  measurement_state ops.usage_measurement_state,
  expected_item_count bigint,
  observed_item_count bigint,
  observed_quantity numeric(24,6),
  normalization_basis_kind ops.usage_normalization_basis_kind,
  normalization_input_quantity numeric(24,6),
  coverage_digest char(64),
  source_system_id text,
  source_window_identity_hmac char(64),
  source_window_hmac_key_version text,
  source_cursor_set_digest char(64),
  source_record_set_digest char(64),
  source_signature_digest char(64),
  meter_policy_version text,
  meter_policy_digest char(64),
  measured_at timestamptz,
  expected_head_id uuid,
  expected_head_version bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_usage_fact_import_v1 AS (
  root_usage_fact_id uuid,
  revision bigint,
  fact_effect ops.usage_fact_effect,
  supersedes_usage_fact_id uuid,
  predecessor_record_digest char(64),
  deployment_id uuid,
  organization_id uuid,
  contract_period_id uuid,
  contract_id uuid,
  tariff_version_id uuid,
  sku ops.commercial_sku,
  accounting_timezone text,
  accounting_policy_digest char(64),
  period_start date,
  period_end date,
  measurement_window_digest char(64),
  measurement_state ops.usage_measurement_state,
  expected_item_count bigint,
  observed_item_count bigint,
  coverage_digest char(64),
  meter_kind ops.usage_meter_kind,
  unit ops.usage_unit,
  quantity numeric(24,6),
  billable_metric ops.billable_metric,
  billable_quantity numeric(24,6),
  billable_unit ops.billable_unit,
  conversion_policy_digest char(64),
  source_receipt_kind ops.usage_receipt_kind,
  source_receipt_id uuid,
  source_receipt_version bigint,
  source_receipt_digest char(64),
  meter_policy_version text,
  meter_policy_digest char(64),
  measured_at timestamptz,
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_usage_window_import_v1 AS (
  receipt ops.economics_usage_receipt_import_v1,
  fact ops.economics_usage_fact_import_v1
);

CREATE TYPE ops.economics_invoice_header_import_v1 AS (
  root_invoice_id uuid,
  invoice_revision bigint,
  invoice_effect ops.invoice_fact_effect,
  supersedes_invoice_id uuid,
  predecessor_reconciliation_digest char(64),
  deployment_id uuid,
  organization_id uuid,
  contract_period_id uuid,
  contract_id uuid,
  sku ops.commercial_sku,
  accounting_timezone text,
  source_system_id text,
  external_invoice_reference_digest char(64),
  period_start date,
  period_end date,
  billing_cutoff_at timestamptz,
  currency char(3),
  expected_line_count integer,
  expected_line_set_digest char(64),
  expected_usage_membership_count integer,
  expected_usage_membership_set_digest char(64),
  expected_usage_fact_set_digest char(64),
  expected_usage_window_receipt_set_digest char(64),
  expected_tariff_set_digest char(64),
  expected_discount_leaf_set_digest char(64),
  expected_correction_set_digest char(64),
  expected_contract_state_interval_set_digest char(64),
  tax_policy_digest char(64),
  rounding_policy_digest char(64),
  expected_subtotal numeric(24,6),
  expected_discount_total numeric(24,6),
  expected_taxable_amount numeric(24,6),
  expected_tax_total numeric(24,6),
  expected_correction_total numeric(24,6),
  expected_invoice_total numeric(24,6),
  provider_receipt_digest char(64),
  source_record_digest char(64),
  signature_digest char(64),
  import_receipt_digest char(64),
  accounting_policy_digest char(64),
  expected_reconciliation_digest char(64),
  reconciled_at timestamptz,
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_reconciliation_digest char(64)
);

CREATE TYPE ops.economics_invoice_line_import_v1 AS (
  line_ordinal integer,
  line_kind text,
  sku ops.commercial_sku,
  service_period_start date,
  service_period_end date,
  usage_fact_id uuid,
  usage_fact_digest char(64),
  tariff_version_id uuid,
  tariff_record_digest char(64),
  discount_decision_id uuid,
  discount_record_digest char(64),
  discount_source_ordinal integer,
  corrects_line_id uuid,
  meter_kind text,
  quantity numeric(24,6),
  unit_price numeric(24,6),
  expected_subtotal numeric(24,6),
  expected_discount_amount numeric(24,6),
  expected_taxable_amount numeric(24,6),
  tax_category text,
  tax_rate_basis_points integer,
  tax_exemption_digest char(64),
  tax_policy_digest char(64),
  expected_tax_amount numeric(24,6),
  expected_correction_amount numeric(24,6),
  correction_set_digest char(64),
  rounding_policy_digest char(64),
  expected_line_total numeric(24,6),
  currency char(3),
  source_line_digest char(64)
);

CREATE TYPE ops.economics_invoice_membership_import_v1 AS (
  root_membership_id uuid,
  revision bigint,
  membership_effect ops.invoice_usage_membership_effect,
  supersedes_membership_id uuid,
  predecessor_invoice_id uuid,
  predecessor_membership_digest char(64),
  deployment_id uuid,
  organization_id uuid,
  contract_period_id uuid,
  contract_id uuid,
  sku ops.commercial_sku,
  accounting_timezone text,
  currency char(3),
  usage_root_fact_id uuid,
  usage_fact_id uuid,
  usage_fact_revision bigint,
  usage_fact_digest char(64),
  usage_window_receipt_id uuid,
  usage_window_receipt_version bigint,
  usage_window_receipt_digest char(64),
  meter_kind ops.usage_meter_kind,
  period_start date,
  period_end date,
  measurement_window_digest char(64),
  measurement_state ops.usage_measurement_state,
  membership_kind ops.invoice_usage_membership_kind,
  billable_quantity numeric(24,6),
  included_quantity numeric(24,6),
  charged_quantity numeric(24,6),
  billable_unit ops.billable_unit,
  invoice_line_ordinal integer,
  allocation_policy_digest char(64),
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_invoice_import_v1 AS (
  invoice ops.economics_invoice_header_import_v1,
  lines ops.economics_invoice_line_import_v1[],
  memberships ops.economics_invoice_membership_import_v1[],
  discounts ops.economics_discount_source_import_v1[]
);

CREATE TYPE ops.economics_revenue_row_import_v1 AS (
  deployment_id uuid,
  organization_id uuid,
  contract_period_id uuid,
  contract_id uuid,
  invoice_id uuid,
  invoice_line_id uuid,
  invoice_line_digest char(64),
  sku ops.commercial_sku,
  accounting_timezone text,
  recognition_period_start date,
  recognition_period_end date,
  amount numeric(24,6),
  currency char(3),
  recognition_policy_version text,
  accounting_policy_digest char(64),
  source_receipt_digest char(64),
  source_record_digest char(64),
  signature_digest char(64),
  import_receipt_digest char(64),
  recognized_at timestamptz
);

CREATE TYPE ops.economics_revenue_import_v1 AS (
  expected_invoice_id uuid,
  expected_invoice_revision bigint,
  expected_invoice_record_digest char(64),
  expected_invoice_reconciliation_digest char(64),
  rows ops.economics_revenue_row_import_v1[]
);

CREATE TYPE ops.economics_accounting_correction_import_v1 AS (
  deployment_id uuid,
  scope_kind ops.accounting_scope_kind,
  organization_id uuid,
  accounting_timezone text,
  accounting_policy_digest char(64),
  root_correction_id uuid,
  revision bigint,
  correction_sequence bigint,
  correction_kind ops.accounting_correction_kind,
  supersedes_correction_id uuid,
  reverses_correction_id uuid,
  predecessor_correction_digest char(64),
  source_system_id text,
  source_record_identity_digest char(64),
  correction_identity_digest char(64),
  target_fact_kind ops.accounting_fact_kind,
  target_amount_kind ops.accounting_target_amount_kind,
  target_fact_id uuid,
  target_cost_event_id uuid,
  target_cost_allocation_id uuid,
  target_invoice_fact_id uuid,
  target_invoice_line_fact_id uuid,
  target_revenue_fact_id uuid,
  target_fact_digest char(64),
  period_start date,
  period_end date,
  amount numeric(24,6),
  effective_delta numeric(24,6),
  expected_resulting_effective_amount numeric(24,6),
  expected_resulting_correction_set_digest char(64),
  currency char(3),
  reason_code ops.accounting_correction_reason,
  proposed_by uuid,
  approver_id uuid,
  decision_digest char(64),
  source_receipt_digest char(64),
  signature_digest char(64),
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_accounting_corrections_import_v1 AS (
  rows ops.economics_accounting_correction_import_v1[]
);

CREATE TYPE ops.economics_cash_application_import_v1 AS (
  root_fact_id uuid,
  revision bigint,
  fact_effect text,
  supersedes_fact_id uuid,
  predecessor_fact_digest char(64),
  invoice_fact_id uuid,
  invoice_fact_digest char(64),
  invoice_reconciliation_digest char(64),
  source_kind text,
  source_system_id text,
  source_settlement_identity_hmac char(64),
  source_settlement_hmac_key_version text,
  source_settlement_amount numeric(24,6),
  applied_amount numeric(24,6),
  currency char(3),
  source_record_digest char(64),
  source_signature_digest char(64),
  import_receipt_digest char(64),
  applied_at timestamptz,
  expected_invoice_revision bigint,
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_cash_applications_import_v1 AS (
  rows ops.economics_cash_application_import_v1[]
);

CREATE TYPE ops.economics_tax_invoice_import_v1 AS (
  root_receipt_id uuid,
  revision bigint,
  receipt_effect text,
  supersedes_receipt_id uuid,
  predecessor_receipt_digest char(64),
  invoice_fact_id uuid,
  invoice_fact_digest char(64),
  invoice_reconciliation_digest char(64),
  taxable_amount numeric(24,6),
  tax_amount numeric(24,6),
  currency char(3),
  issuance_state text,
  approval_number_hmac char(64),
  approval_number_hmac_key_version text,
  asp_receipt_reference_hmac char(64),
  asp_receipt_reference_hmac_key_version text,
  asp_receipt_digest char(64),
  source_system_id text,
  source_record_digest char(64),
  source_signature_digest char(64),
  import_receipt_digest char(64),
  issued_at timestamptz,
  cancelled_at timestamptz,
  expected_invoice_revision bigint,
  expected_head_id uuid,
  expected_head_revision bigint,
  expected_head_digest char(64)
);

CREATE TYPE ops.economics_tax_invoices_import_v1 AS (
  rows ops.economics_tax_invoice_import_v1[]
);

CREATE TYPE ops.economics_collection_failure_import_v1 AS (
  authority_kind text,
  provider_charge_attempt_id uuid,
  provider_charge_attempt_digest char(64),
  provider_fetch_digest char(64),
  invoice_fact_id uuid,
  invoice_fact_digest char(64),
  invoice_reconciliation_digest char(64),
  expected_invoice_revision bigint,
  signed_evidence_segment_id uuid,
  signed_evidence_segment_digest char(64),
  task_assignee_id uuid,
  task_due_at timestamptz,
  reason_code text,
  reason_digest char(64)
);

CREATE TYPE ops.economics_import_operation_v1 AS (
  import_kind text,
  record_commercial_qualification ops.economics_qualification_import_v1,
  import_cost_allocation_close ops.economics_cost_close_import_v1,
  create_tariff_version ops.economics_tariff_import_v1,
  record_commercial_contract_period ops.economics_contract_import_v1,
  record_usage_window ops.economics_usage_window_import_v1,
  record_invoice ops.economics_invoice_import_v1,
  record_revenue ops.economics_revenue_import_v1,
  record_accounting_correction ops.economics_accounting_corrections_import_v1,
  record_cash_application ops.economics_cash_applications_import_v1,
  record_tax_invoice_issuance ops.economics_tax_invoices_import_v1,
  record_collection_failure ops.economics_collection_failure_import_v1
);

CREATE TYPE ops.economics_import_result_row_v1 AS (
  resource_kind text,
  resource_id uuid,
  resource_version bigint,
  resource_digest char(64)
);

CREATE TYPE ops.economics_import_apply_receipt_v1 AS (
  operation_id text,
  result_rows ops.economics_import_result_row_v1[],
  result_count bigint,
  result_set_digest char(64),
  primary_resource_kind text,
  primary_resource_id uuid,
  primary_resource_version bigint,
  primary_resource_digest char(64),
  notification_outbox_event_id uuid,
  applied_at timestamptz
);

CREATE FUNCTION ops.economics_closed_composite_required_v1(
  p_value jsonb,
  p_nullable_keys text[]
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
  SELECT COALESCE(
    jsonb_typeof(p_value)='object'
    AND NOT EXISTS (
      SELECT 1
      FROM jsonb_each(p_value) AS field(key,value)
      WHERE value='null'::jsonb
        AND NOT key=ANY(COALESCE(p_nullable_keys,'{}'::text[]))
    ),
    false
  )
$$;
ALTER FUNCTION ops.economics_closed_composite_required_v1(jsonb,text[])
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.economics_closed_composite_required_v1(jsonb,text[]) FROM PUBLIC;

CREATE FUNCTION ops.economics_finite_numeric_v1(
  p_value numeric
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
  SELECT COALESCE(
    p_value::text NOT IN ('NaN','Infinity','-Infinity'),
    false
  )
$$;
ALTER FUNCTION ops.economics_finite_numeric_v1(numeric)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_finite_numeric_v1(numeric) FROM PUBLIC;

CREATE FUNCTION ops.economics_uuid_array_is_sorted_unique_v1(
  p_values uuid[]
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
  SELECT COALESCE(
    p_values IS NOT NULL
    AND cardinality(p_values)=(
      SELECT count(DISTINCT value) FROM unnest(p_values) AS item(value)
    )
    AND NOT EXISTS (
      SELECT 1 FROM unnest(p_values) AS item(value) WHERE value IS NULL
    )
    AND p_values=ARRAY(
      SELECT value FROM unnest(p_values) AS item(value) ORDER BY value
    ),
    false
  )
$$;
ALTER FUNCTION ops.economics_uuid_array_is_sorted_unique_v1(uuid[])
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.economics_uuid_array_is_sorted_unique_v1(uuid[]) FROM PUBLIC;

CREATE FUNCTION ops.sha256_text_array_is_valid_v1(
  p_values text[]
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
  SELECT COALESCE(
    p_values IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM unnest(p_values) AS item(value)
      WHERE value IS NULL OR value!~'^[0-9a-f]{64}$'
    ),
    false
  )
$$;
ALTER FUNCTION ops.sha256_text_array_is_valid_v1(text[])
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.sha256_text_array_is_valid_v1(text[]) FROM PUBLIC;

CREATE FUNCTION ops.economics_acquisition_source_import_v1_is_valid(
  p_value ops.economics_acquisition_source_import_v1
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_append ops.acquisition_source_receipt_input_v1;
BEGIN
  IF p_value IS NULL
     OR p_value.resolution IS NULL
     OR p_value.evidence_segment_id IS NULL
     OR p_value.evidence_segment_digest !~ '^[0-9a-f]{64}$'
     OR p_value.source_signature_digest !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  IF p_value.resolution='EXISTING' THEN
    RETURN COALESCE(p_value.append_value IS NULL
      AND p_value.existing_receipt_id IS NOT NULL
      AND p_value.existing_receipt_revision>0
      AND p_value.existing_receipt_digest~'^[0-9a-f]{64}$'
      AND p_value.expected_head_id=p_value.existing_receipt_id
      AND p_value.expected_head_revision=p_value.existing_receipt_revision
      AND p_value.expected_head_digest=p_value.existing_receipt_digest,false);
  END IF;
  IF p_value.resolution<>'APPEND' OR p_value.append_value IS NULL
     OR num_nonnulls(
       p_value.existing_receipt_id,p_value.existing_receipt_revision,
       p_value.existing_receipt_digest
     )<>0 THEN
    RETURN false;
  END IF;
  v_append:=p_value.append_value;
  IF v_append.revision IS NULL OR v_append.revision<1
     OR NOT ops.economics_closed_composite_required_v1(
       to_jsonb(v_append),
       ARRAY[
         'root_receipt_id','supersedes_receipt_id',
         'predecessor_receipt_digest'
       ]
     )
     OR v_append.receipt_effect NOT IN ('ORIGINAL','REPLACEMENT','REVERSAL')
     OR v_append.source_kind NOT IN (
       'ORGANIC_SEARCH','REFERRAL','DIRECT','PARTNER','EVENT','PAID_SEARCH',
       'PAID_SOCIAL','CONTENT','OUTBOUND','OTHER_REVIEWED'
     )
     OR v_append.source_signature_digest
       IS DISTINCT FROM p_value.source_signature_digest
     OR v_append.receipt_digest !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  RETURN COALESCE((
    v_append.revision=1
    AND v_append.receipt_effect='ORIGINAL'
    AND num_nonnulls(
      v_append.root_receipt_id,v_append.supersedes_receipt_id,
      v_append.predecessor_receipt_digest,p_value.expected_head_id,
      p_value.expected_head_revision,p_value.expected_head_digest
    )=0
  ) OR (
    v_append.revision>1
    AND v_append.receipt_effect IN ('REPLACEMENT','REVERSAL')
    AND num_nonnulls(
      v_append.root_receipt_id,v_append.supersedes_receipt_id,
      v_append.predecessor_receipt_digest,p_value.expected_head_id,
      p_value.expected_head_revision,p_value.expected_head_digest
    )=6
    AND v_append.supersedes_receipt_id=p_value.expected_head_id
    AND v_append.predecessor_receipt_digest=p_value.expected_head_digest
    AND v_append.revision=p_value.expected_head_revision+1
  ),false);
END
$$;
ALTER FUNCTION ops.economics_acquisition_source_import_v1_is_valid(
  ops.economics_acquisition_source_import_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_acquisition_source_import_v1_is_valid(
  ops.economics_acquisition_source_import_v1
) FROM PUBLIC;

CREATE FUNCTION ops.economics_fx_rate_source_import_v1_is_valid(
  p_value ops.economics_fx_rate_source_import_v1
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_append ops.economics_fx_rate_append_v1;
BEGIN
  IF p_value IS NULL
     OR p_value.resolution IS NULL
     OR p_value.evidence_segment_id IS NULL
     OR p_value.evidence_segment_digest !~ '^[0-9a-f]{64}$'
     OR p_value.source_signature_digest !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  IF p_value.resolution='EXISTING' THEN
    RETURN COALESCE(p_value.append_value IS NULL
      AND p_value.existing_rate_id IS NOT NULL
      AND p_value.existing_rate_revision>0
      AND p_value.existing_rate_digest~'^[0-9a-f]{64}$'
      AND p_value.expected_head_id=p_value.existing_rate_id
      AND p_value.expected_head_revision=p_value.existing_rate_revision
      AND p_value.expected_head_digest=p_value.existing_rate_digest,false);
  END IF;
  IF p_value.resolution<>'APPEND' OR p_value.append_value IS NULL
     OR num_nonnulls(
       p_value.existing_rate_id,p_value.existing_rate_revision,
       p_value.existing_rate_digest
     )<>0 THEN
    RETURN false;
  END IF;
  v_append:=p_value.append_value;
  IF v_append.revision IS NULL OR v_append.revision<1
     OR NOT ops.economics_closed_composite_required_v1(
       to_jsonb(v_append),
       ARRAY[
         'root_rate_id','supersedes_rate_id','rate','correction_reason',
         'approver_id','decision_digest'
       ]
     )
     OR num_nonnulls(v_append.approver_id,v_append.decision_digest)<>0
     OR (
       v_append.fact_kind IN ('OBSERVATION','REPLACEMENT')
       AND NOT ops.economics_finite_numeric_v1(v_append.rate)
       OR v_append.fact_kind='WITHDRAWAL' AND v_append.rate IS NOT NULL
     )
     OR v_append.signature_digest
       IS DISTINCT FROM p_value.source_signature_digest
     OR v_append.expected_record_digest !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  RETURN COALESCE((
    v_append.revision=1 AND v_append.fact_kind='OBSERVATION'
    AND num_nonnulls(
      v_append.root_rate_id,v_append.supersedes_rate_id,
      v_append.correction_reason,v_append.approver_id,
      v_append.decision_digest,p_value.expected_head_id,
      p_value.expected_head_revision,p_value.expected_head_digest
    )=0
  ) OR (
    v_append.revision>1 AND v_append.fact_kind IN ('REPLACEMENT','WITHDRAWAL')
    AND num_nonnulls(
      v_append.root_rate_id,v_append.supersedes_rate_id,
      v_append.correction_reason,p_value.expected_head_id,
      p_value.expected_head_revision,p_value.expected_head_digest
    )=6
    AND v_append.supersedes_rate_id=p_value.expected_head_id
    AND v_append.revision=p_value.expected_head_revision+1
  ),false);
END
$$;
ALTER FUNCTION ops.economics_fx_rate_source_import_v1_is_valid(
  ops.economics_fx_rate_source_import_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_fx_rate_source_import_v1_is_valid(
  ops.economics_fx_rate_source_import_v1
) FROM PUBLIC;

CREATE FUNCTION ops.economics_discount_source_import_v1_is_valid(
  p_value ops.economics_discount_source_import_v1
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_append ops.economics_discount_append_v1;
BEGIN
  IF p_value IS NULL
     OR p_value.resolution IS NULL
     OR p_value.evidence_segment_id IS NULL
     OR p_value.evidence_segment_digest !~ '^[0-9a-f]{64}$'
     OR p_value.source_signature_digest !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  IF p_value.resolution='EXISTING' THEN
    RETURN COALESCE(p_value.append_value IS NULL
      AND p_value.existing_discount_id IS NOT NULL
      AND p_value.existing_discount_revision>0
      AND p_value.existing_discount_digest~'^[0-9a-f]{64}$'
      AND p_value.expected_head_id=p_value.existing_discount_id
      AND p_value.expected_head_revision=p_value.existing_discount_revision
      AND p_value.expected_head_digest=p_value.existing_discount_digest,false);
  END IF;
  IF p_value.resolution<>'APPEND' OR p_value.append_value IS NULL
     OR num_nonnulls(
       p_value.existing_discount_id,p_value.existing_discount_revision,
       p_value.existing_discount_digest
     )<>0 THEN
    RETURN false;
  END IF;
  v_append:=p_value.append_value;
  IF v_append.revision IS NULL OR v_append.revision<1
     OR NOT ops.economics_closed_composite_required_v1(
       to_jsonb(v_append),
       ARRAY[
         'root_discount_id','supersedes_discount_id','basis_points',
         'oversight_reason','oversight_expires_at','oversight_approver_id',
         'oversight_decision_digest','proposed_by','approver_id',
         'decision_digest'
       ]
     )
     OR num_nonnulls(
       v_append.oversight_expires_at,v_append.oversight_approver_id,
       v_append.oversight_decision_digest,v_append.proposed_by,
       v_append.approver_id,v_append.decision_digest
     )<>0
     OR NOT ops.economics_finite_numeric_v1(
       v_append.undiscounted_p75_revenue_amount
     )
     OR NOT ops.economics_finite_numeric_v1(
       v_append.discounted_p75_revenue_amount
     )
     OR NOT ops.economics_finite_numeric_v1(v_append.p75_variable_cost_amount)
     OR NOT COALESCE((
       v_append.projected_margin_after_discount_basis_points
         >=v_append.required_variable_gross_margin_basis_points
       AND v_append.oversight_reason IS NULL
     ) OR (
       v_append.projected_margin_after_discount_basis_points
         <v_append.required_variable_gross_margin_basis_points
       AND v_append.oversight_reason IS NOT NULL
       AND btrim(v_append.oversight_reason)<>''
     ),false)
     OR v_append.signature_digest
       IS DISTINCT FROM p_value.source_signature_digest
     OR v_append.expected_record_digest !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  RETURN COALESCE((
    v_append.revision=1
    AND num_nonnulls(
      v_append.root_discount_id,v_append.supersedes_discount_id,
      p_value.expected_head_id,p_value.expected_head_revision,
      p_value.expected_head_digest
    )=0
  ) OR (
    v_append.revision>1
    AND num_nonnulls(
      v_append.root_discount_id,v_append.supersedes_discount_id,
      p_value.expected_head_id,p_value.expected_head_revision,
      p_value.expected_head_digest
    )=5
    AND v_append.supersedes_discount_id=p_value.expected_head_id
    AND v_append.revision=p_value.expected_head_revision+1
  ),false);
END
$$;
ALTER FUNCTION ops.economics_discount_source_import_v1_is_valid(
  ops.economics_discount_source_import_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_discount_source_import_v1_is_valid(
  ops.economics_discount_source_import_v1
) FROM PUBLIC;

CREATE FUNCTION ops.economics_import_result_row_v1_is_valid(
  p_value ops.economics_import_result_row_v1
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
  SELECT COALESCE(
    p_value IS NOT NULL
    AND p_value.resource_id IS NOT NULL
    AND p_value.resource_digest~'^[0-9a-f]{64}$'
    AND (
      p_value.resource_kind IN (
        'ACQUISITION_SOURCE_RECEIPT','COMMERCIAL_QUALIFICATION_RECEIPT',
        'FX_RATE_FACT','COST_ALLOCATION_PERIOD','COST_ALLOCATION_LINE',
        'COMMERCIAL_CONTRACT_PERIOD','OFFER_PROFILE_CAPABILITY',
        'USAGE_WINDOW_RECEIPT','USAGE_FACT','DISCOUNT_DECISION',
        'INVOICE_FACT','INVOICE_LINE_FACT','INVOICE_USAGE_MEMBERSHIP',
        'ACCOUNTING_CORRECTION','CASH_APPLICATION_FACT',
        'TAX_INVOICE_ISSUANCE_RECEIPT','COLLECTION_REVIEW_TASK',
        'NOTIFICATION_OUTBOX_EVENT'
      ) AND p_value.resource_version>0
      OR p_value.resource_kind IN (
        'TARIFF_VERSION','REVENUE_FACT','ECONOMICS_IMPORT_AUDIT_EVENT'
      ) AND p_value.resource_version IS NULL
    ),false
  )
$$;
ALTER FUNCTION ops.economics_import_result_row_v1_is_valid(
  ops.economics_import_result_row_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_import_result_row_v1_is_valid(
  ops.economics_import_result_row_v1
) FROM PUBLIC;

CREATE FUNCTION ops.economics_import_apply_receipt_v1_is_valid(
  p_value ops.economics_import_apply_receipt_v1
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
  WITH rows AS (
    SELECT ROW(
        result_entry.resource_kind,
        result_entry.resource_id,
        result_entry.resource_version,
        result_entry.resource_digest
      )::ops.economics_import_result_row_v1 AS value,
      result_entry.ordinality,
      lag(result_entry.resource_kind)
        OVER (ORDER BY result_entry.ordinality) AS prior_kind,
      lag(result_entry.resource_id)
        OVER (ORDER BY result_entry.ordinality) AS prior_id
    FROM unnest(p_value.result_rows) WITH ORDINALITY
      AS result_entry(
        resource_kind,resource_id,resource_version,resource_digest,ordinality
      )
  ), canonical AS (
    SELECT ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','economics-import-result-set.v1',
      'operationId',p_value.operation_id,
      'rows',to_jsonb(p_value.result_rows)
    )) AS bytes
  )
  SELECT COALESCE(
    p_value IS NOT NULL
    AND p_value.operation_id IN (
      'recordCommercialQualification','importCostAllocationClose',
      'createTariffVersion','recordCommercialContractPeriod',
      'recordUsageWindow','recordInvoice','recordRevenue',
      'recordAccountingCorrection','recordCashApplication',
      'recordTaxInvoiceIssuance','recordCollectionFailure'
    )
    AND p_value.result_count=cardinality(p_value.result_rows)
    AND p_value.result_count>0
    AND p_value.result_set_digest=(
      SELECT encode(extensions.digest(bytes,'sha256'),'hex') FROM canonical
    )
    AND NOT EXISTS (
      SELECT 1 FROM rows
      WHERE NOT ops.economics_import_result_row_v1_is_valid(value) IS TRUE
        OR prior_kind>(value).resource_kind
        OR prior_kind=(value).resource_kind AND prior_id>=(value).resource_id
    )
    AND EXISTS (
      SELECT 1 FROM rows
      WHERE (value).resource_kind=p_value.primary_resource_kind
        AND (value).resource_id=p_value.primary_resource_id
        AND (value).resource_version IS NOT DISTINCT FROM
          p_value.primary_resource_version
        AND (value).resource_digest=p_value.primary_resource_digest
    )
    AND (
      p_value.operation_id='recordCollectionFailure'
      AND p_value.notification_outbox_event_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM rows
        WHERE (value).resource_kind='NOTIFICATION_OUTBOX_EVENT'
          AND (value).resource_id=p_value.notification_outbox_event_id
      )
      OR p_value.operation_id<>'recordCollectionFailure'
      AND p_value.notification_outbox_event_id IS NULL
    ),false
  )
$$;
ALTER FUNCTION ops.economics_import_apply_receipt_v1_is_valid(
  ops.economics_import_apply_receipt_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_import_apply_receipt_v1_is_valid(
  ops.economics_import_apply_receipt_v1
) FROM PUBLIC;

CREATE FUNCTION ops.economics_import_operation_v1_is_valid(
  p_value ops.economics_import_operation_v1
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_capability ops.economics_offer_capability_import_v1;
  v_ordinal bigint;
  v_capability_row record;
  v_expected_codes ops.offer_capability_code[] := ARRAY[
    'PUBLIC_WEB','VERIFIED_EMAIL','API_EXPORT','SIGNED_WEBHOOK',
    'DAILY_DIGEST','WEEKLY_DIGEST','SMS','TELEGRAM','WHATSAPP',
    'LINE','KAKAO','VOICE'
  ]::ops.offer_capability_code[];
  v_collection ops.economics_collection_failure_import_v1;
BEGIN
  IF p_value IS NULL OR p_value.import_kind IS NULL
    OR p_value.import_kind NOT IN (
      'recordCommercialQualification','importCostAllocationClose',
      'createTariffVersion','recordCommercialContractPeriod',
      'recordUsageWindow','recordInvoice','recordRevenue',
      'recordAccountingCorrection','recordCashApplication',
      'recordTaxInvoiceIssuance','recordCollectionFailure'
    ) OR num_nonnulls(
      p_value.record_commercial_qualification,
      p_value.import_cost_allocation_close,
      p_value.create_tariff_version,
      p_value.record_commercial_contract_period,
      p_value.record_usage_window,
      p_value.record_invoice,
      p_value.record_revenue,
      p_value.record_accounting_correction,
      p_value.record_cash_application,
      p_value.record_tax_invoice_issuance,
      p_value.record_collection_failure
    )<>1 THEN
    RETURN false;
  END IF;

  CASE p_value.import_kind
    WHEN 'recordCommercialQualification' THEN
      RETURN COALESCE((
        p_value.record_commercial_qualification IS NOT NULL
        AND ops.economics_acquisition_source_import_v1_is_valid(
          (p_value.record_commercial_qualification).acquisition_source
        ) IS TRUE
        AND (
          ((p_value.record_commercial_qualification).acquisition_source).resolution
            ='APPEND'
          AND num_nonnulls(
            (p_value.record_commercial_qualification)
              .acquisition_source_receipt_id,
            (p_value.record_commercial_qualification)
              .acquisition_source_receipt_digest
          )=0
          OR ((p_value.record_commercial_qualification).acquisition_source)
              .resolution='EXISTING'
          AND (p_value.record_commercial_qualification)
              .acquisition_source_receipt_id
            =((p_value.record_commercial_qualification).acquisition_source)
              .existing_receipt_id
          AND (p_value.record_commercial_qualification)
              .acquisition_source_receipt_digest
            =((p_value.record_commercial_qualification).acquisition_source)
              .existing_receipt_digest
        )
        AND ops.economics_closed_composite_required_v1(
          to_jsonb(p_value.record_commercial_qualification),
          ARRAY[
            'supersedes_receipt_id','predecessor_receipt_digest',
            'acquisition_source_receipt_id',
            'acquisition_source_receipt_digest','expected_head_id',
            'expected_head_revision','expected_head_digest'
          ]
        )
      ),false);
    WHEN 'importCostAllocationClose' THEN
      RETURN COALESCE((
        p_value.import_cost_allocation_close IS NOT NULL
        AND (p_value.import_cost_allocation_close).period IS NOT NULL
        AND cardinality((p_value.import_cost_allocation_close).lines)>0
        AND (p_value.import_cost_allocation_close).fx_rates IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM unnest(
            (p_value.import_cost_allocation_close).fx_rates
          ) AS source(value)
          WHERE NOT ops.economics_fx_rate_source_import_v1_is_valid(value)
            IS TRUE
        )
        AND ops.economics_closed_composite_required_v1(
          to_jsonb((p_value.import_cost_allocation_close).period),
          ARRAY[
            'supersedes_period_revision_id','expected_cost_count',
            'expected_cost_capture_coverage','incomplete_reason_set_digest',
            'unknown_cost_scope_digest','expected_head_id',
            'expected_head_version','expected_head_digest'
          ]
        )
        AND NOT EXISTS (
          SELECT 1 FROM unnest(
            (p_value.import_cost_allocation_close).lines
          ) AS line(value)
          WHERE value IS NULL OR NOT ops.economics_closed_composite_required_v1(
            to_jsonb(value),
            ARRAY[
              'fx_rate_fact_id','fx_source_ordinal','job_id','agent_run_id','case_id',
              'organization_id','outcome_fact_id',
              'acquisition_campaign_digest','acquisition_source_receipt_id',
              'acquisition_source_receipt_digest',
              'acquisition_attribution_state',
              'unattributed_acquisition_pool_digest','driver_quantity',
              'driver_total_quantity','allocation_ratio'
            ]
          ) OR (
            value.source_currency
              =((p_value.import_cost_allocation_close).period).currency
            AND num_nonnulls(value.fx_rate_fact_id,value.fx_source_ordinal)=0
            OR value.source_currency
              <>((p_value.import_cost_allocation_close).period).currency
            AND value.fx_source_ordinal BETWEEN 1 AND cardinality(
              (p_value.import_cost_allocation_close).fx_rates
            )
            AND (
              (((p_value.import_cost_allocation_close).fx_rates)
                [value.fx_source_ordinal]).resolution='APPEND'
              AND value.fx_rate_fact_id IS NULL
              OR (((p_value.import_cost_allocation_close).fx_rates)
                [value.fx_source_ordinal]).resolution='EXISTING'
              AND value.fx_rate_fact_id=(((
                p_value.import_cost_allocation_close).fx_rates)
                [value.fx_source_ordinal]).existing_rate_id
            )
          ) IS NOT TRUE
        )
        AND NOT EXISTS (
          SELECT 1 FROM unnest(ARRAY[
            ((p_value.import_cost_allocation_close).period)
              .expected_cost_capture_coverage,
            ((p_value.import_cost_allocation_close).period)
              .expected_direct_eligible_amount,
            ((p_value.import_cost_allocation_close).period)
              .expected_direct_allocated_amount,
            ((p_value.import_cost_allocation_close).period)
              .expected_captured_cost_amount,
            ((p_value.import_cost_allocation_close).period)
              .expected_attributed_cost_amount,
            ((p_value.import_cost_allocation_close).period)
              .expected_unallocated_amount,
            ((p_value.import_cost_allocation_close).period)
              .expected_direct_coverage,
            ((p_value.import_cost_allocation_close).period)
              .expected_total_coverage
          ]) value
          WHERE value IS NOT NULL
            AND NOT ops.economics_finite_numeric_v1(value)
        )
        AND NOT EXISTS (
          SELECT 1
          FROM unnest((p_value.import_cost_allocation_close).lines) line
          CROSS JOIN LATERAL unnest(ARRAY[
            line.source_amount,line.reporting_source_amount,
            line.driver_quantity,line.driver_total_quantity,
            line.allocation_ratio,line.rounding_adjustment,line.allocated_amount
          ]) value
          WHERE value IS NOT NULL
            AND NOT ops.economics_finite_numeric_v1(value)
        )
      ),false);
    WHEN 'createTariffVersion' THEN
      RETURN COALESCE((
        p_value.create_tariff_version IS NOT NULL
        AND (p_value.create_tariff_version).cost_allocation_row_kind='PERIOD'
        AND ops.economics_closed_composite_required_v1(
          to_jsonb(p_value.create_tariff_version),
          ARRAY[
            'sla_add_on_amount','sla_policy_version','sla_policy_digest',
            'sla_target_availability_ratio','sla_capability_set_digest',
            'sla_exclusion_schedule_digest',
            'sla_service_credit_schedule_digest',
            'sla_measurement_policy_digest',
            'sla_policy_source_receipt_digest','sla_policy_signature_digest',
            'margin_exception_reason','margin_exception_expires_at',
            'oversight_approver_id','oversight_decision_digest',
            'proposed_by','approver_id','decision_digest',
            'expected_current_tariff_id','expected_current_tariff_digest'
          ]
        )
        AND num_nonnulls(
          (p_value.create_tariff_version).margin_exception_expires_at,
          (p_value.create_tariff_version).oversight_approver_id,
          (p_value.create_tariff_version).oversight_decision_digest,
          (p_value.create_tariff_version).proposed_by,
          (p_value.create_tariff_version).approver_id,
          (p_value.create_tariff_version).decision_digest
        )=0
        AND (
          (p_value.create_tariff_version)
            .expected_projected_p75_variable_gross_margin_basis_points
            >=(p_value.create_tariff_version)
              .expected_required_variable_gross_margin_basis_points
          AND (p_value.create_tariff_version).margin_exception_reason IS NULL
          OR (p_value.create_tariff_version)
            .expected_projected_p75_variable_gross_margin_basis_points
            <(p_value.create_tariff_version)
              .expected_required_variable_gross_margin_basis_points
          AND (p_value.create_tariff_version).margin_exception_reason IS NOT NULL
          AND btrim((p_value.create_tariff_version).margin_exception_reason)<>''
        )
        AND NOT EXISTS (
          SELECT 1 FROM unnest(ARRAY[
            (p_value.create_tariff_version).workspace_base_amount,
            (p_value.create_tariff_version).active_contributor_block_amount,
            (p_value.create_tariff_version).included_processing_credits,
            (p_value.create_tariff_version).processing_credit_overage_amount,
            (p_value.create_tariff_version).included_storage_gb_month,
            (p_value.create_tariff_version).storage_gb_month_overage_amount,
            (p_value.create_tariff_version).included_api_record_units,
            (p_value.create_tariff_version).api_record_unit_overage_amount,
            (p_value.create_tariff_version).sla_add_on_amount,
            (p_value.create_tariff_version).sla_target_availability_ratio,
            (p_value.create_tariff_version).cost_capture_coverage,
            (p_value.create_tariff_version).direct_cost_coverage,
            (p_value.create_tariff_version).total_cost_coverage,
            (p_value.create_tariff_version).p75_revenue_amount,
            (p_value.create_tariff_version).p75_variable_cost_amount
          ]) value
          WHERE value IS NOT NULL
            AND NOT ops.economics_finite_numeric_v1(value)
        )
      ),false);
    WHEN 'recordCommercialContractPeriod' THEN
      IF p_value.record_commercial_contract_period IS NULL
        OR cardinality(
          (p_value.record_commercial_contract_period).capabilities
        )<>12 OR NOT ops.economics_closed_composite_required_v1(
          to_jsonb(p_value.record_commercial_contract_period),
          ARRAY[
            'supersedes_contract_period_id','predecessor_record_digest',
            'sla_policy_version','sla_policy_digest',
            'sla_target_availability_ratio','sla_capability_set_digest',
            'sla_exclusion_schedule_digest',
            'sla_service_credit_schedule_digest',
            'sla_measurement_policy_digest','provisioned_at',
            'approver_id','decision_digest',
            'expected_head_id','expected_head_revision',
            'expected_head_digest','collection_failure_task_id',
            'collection_failure_task_version',
            'collection_failure_task_digest'
          ]
        )
        OR num_nonnulls(
          (p_value.record_commercial_contract_period).approver_id,
          (p_value.record_commercial_contract_period).decision_digest
        )<>0
        OR NOT ops.economics_finite_numeric_v1(
          (p_value.record_commercial_contract_period).binding_committed_amount
        )
        OR (
          (p_value.record_commercial_contract_period).sla_target_availability_ratio
            IS NOT NULL
          AND NOT ops.economics_finite_numeric_v1(
            (p_value.record_commercial_contract_period)
              .sla_target_availability_ratio
          )
        ) THEN
        RETURN false;
      END IF;
      FOR v_capability_row IN
        SELECT value,ordinality
        FROM unnest(
          (p_value.record_commercial_contract_period).capabilities
        ) WITH ORDINALITY AS capability(value,ordinality)
      LOOP
        v_capability := v_capability_row.value;
        v_ordinal := v_capability_row.ordinality;
        IF v_capability IS NULL
          OR v_capability.capability_ordinal<>v_ordinal
          OR v_capability.capability_code<>v_expected_codes[v_ordinal]
          OR NOT ops.economics_closed_composite_required_v1(
            to_jsonb(v_capability),
            ARRAY[
              'included_quantity','overage_unit_price',
              'activation_policy_digest','consent_policy_digest',
              'cost_policy_digest'
            ]
          )
          OR (
            v_capability.included_quantity IS NOT NULL
            AND NOT ops.economics_finite_numeric_v1(
              v_capability.included_quantity
            )
          )
          OR (
            v_capability.overage_unit_price IS NOT NULL
            AND NOT ops.economics_finite_numeric_v1(
              v_capability.overage_unit_price
            )
          ) THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    WHEN 'recordUsageWindow' THEN
      RETURN COALESCE((
        p_value.record_usage_window IS NOT NULL
        AND (p_value.record_usage_window).receipt IS NOT NULL
        AND (p_value.record_usage_window).fact IS NOT NULL
        AND ((p_value.record_usage_window).receipt).receipt_version
          =((p_value.record_usage_window).fact).source_receipt_version
        AND ((p_value.record_usage_window).receipt).root_receipt_id
          =((p_value.record_usage_window).fact).source_receipt_id
        AND ops.economics_closed_composite_required_v1(
          to_jsonb((p_value.record_usage_window).receipt),
          ARRAY[
            'supersedes_receipt_id','predecessor_receipt_digest',
            'observed_quantity','normalization_input_quantity',
            'expected_head_id','expected_head_version','expected_head_digest'
          ]
        )
        AND ops.economics_closed_composite_required_v1(
          to_jsonb((p_value.record_usage_window).fact),
          ARRAY[
            'supersedes_usage_fact_id','predecessor_record_digest',
            'quantity','billable_quantity','expected_head_id',
            'expected_head_revision','expected_head_digest'
          ]
        )
        AND NOT EXISTS (
          SELECT 1 FROM unnest(ARRAY[
            ((p_value.record_usage_window).receipt).observed_quantity,
            ((p_value.record_usage_window).receipt)
              .normalization_input_quantity,
            ((p_value.record_usage_window).fact).quantity,
            ((p_value.record_usage_window).fact).billable_quantity
          ]) value
          WHERE value IS NOT NULL
            AND NOT ops.economics_finite_numeric_v1(value)
        )
      ),false);
    WHEN 'recordInvoice' THEN
      RETURN COALESCE((
        p_value.record_invoice IS NOT NULL
        AND (p_value.record_invoice).invoice IS NOT NULL
        AND cardinality((p_value.record_invoice).lines)>0
        AND (p_value.record_invoice).memberships IS NOT NULL
        AND (p_value.record_invoice).discounts IS NOT NULL
        AND cardinality((p_value.record_invoice).lines)
          =((p_value.record_invoice).invoice).expected_line_count
        AND cardinality((p_value.record_invoice).memberships)
          =((p_value.record_invoice).invoice).expected_usage_membership_count
        AND ops.economics_closed_composite_required_v1(
          to_jsonb((p_value.record_invoice).invoice),
          ARRAY[
            'supersedes_invoice_id','predecessor_reconciliation_digest',
            'expected_head_id','expected_head_revision',
            'expected_head_reconciliation_digest'
          ]
        )
        AND NOT EXISTS (
          SELECT 1 FROM unnest(ARRAY[
            ((p_value.record_invoice).invoice).expected_subtotal,
            ((p_value.record_invoice).invoice).expected_discount_total,
            ((p_value.record_invoice).invoice).expected_taxable_amount,
            ((p_value.record_invoice).invoice).expected_tax_total,
            ((p_value.record_invoice).invoice).expected_correction_total,
            ((p_value.record_invoice).invoice).expected_invoice_total
          ]) value
          WHERE NOT ops.economics_finite_numeric_v1(value)
        )
        AND NOT EXISTS (
          SELECT 1 FROM unnest((p_value.record_invoice).discounts) source
          WHERE NOT ops.economics_discount_source_import_v1_is_valid(source)
            IS TRUE
        )
        AND NOT EXISTS (
          SELECT 1 FROM unnest((p_value.record_invoice).lines) line
          WHERE line IS NULL
          OR ops.economics_closed_composite_required_v1(
            to_jsonb(line),
            ARRAY[
              'usage_fact_id','usage_fact_digest','tariff_version_id',
              'tariff_record_digest','discount_decision_id',
              'discount_record_digest','discount_source_ordinal',
              'corrects_line_id','meter_kind','tax_exemption_digest'
            ]
          ) IS NOT TRUE
          OR (
            line.expected_discount_amount=0
            AND num_nonnulls(
              line.discount_decision_id,line.discount_record_digest,
              line.discount_source_ordinal
            )=0
            OR line.expected_discount_amount>0
            AND line.discount_source_ordinal BETWEEN 1 AND cardinality(
              (p_value.record_invoice).discounts
            )
            AND (
              (((p_value.record_invoice).discounts)
                [line.discount_source_ordinal]).resolution='APPEND'
              AND num_nonnulls(
                line.discount_decision_id,line.discount_record_digest
              )=0
              OR (((p_value.record_invoice).discounts)
                [line.discount_source_ordinal]).resolution='EXISTING'
              AND line.discount_decision_id=(((p_value.record_invoice).discounts)
                [line.discount_source_ordinal]).existing_discount_id
              AND line.discount_record_digest=(((p_value.record_invoice).discounts)
                [line.discount_source_ordinal]).existing_discount_digest
            )
          ) IS NOT TRUE
        )
        AND NOT EXISTS (
          SELECT 1 FROM unnest((p_value.record_invoice).memberships) membership
          WHERE membership IS NULL
            OR ops.economics_closed_composite_required_v1(
              to_jsonb(membership),
              ARRAY[
                'supersedes_membership_id','predecessor_invoice_id',
                'predecessor_membership_digest','invoice_line_ordinal',
                'expected_head_id','expected_head_revision',
                'expected_head_digest'
              ]
            ) IS NOT TRUE
        )
        AND NOT EXISTS (
          SELECT 1
          FROM unnest((p_value.record_invoice).lines) line
          CROSS JOIN LATERAL unnest(ARRAY[
            line.quantity,line.unit_price,line.expected_subtotal,
            line.expected_discount_amount,line.expected_taxable_amount,
            line.expected_tax_amount,line.expected_correction_amount,
            line.expected_line_total
          ]) value
          WHERE NOT ops.economics_finite_numeric_v1(value)
        )
        AND NOT EXISTS (
          SELECT 1
          FROM unnest((p_value.record_invoice).memberships) membership
          CROSS JOIN LATERAL unnest(ARRAY[
            membership.billable_quantity,membership.included_quantity,
            membership.charged_quantity
          ]) value
          WHERE NOT ops.economics_finite_numeric_v1(value)
        )
      ),false);
    WHEN 'recordRevenue' THEN
      RETURN COALESCE((
        p_value.record_revenue IS NOT NULL
        AND (p_value.record_revenue).expected_invoice_id IS NOT NULL
        AND (p_value.record_revenue).expected_invoice_revision>0
        AND (p_value.record_revenue).expected_invoice_record_digest
          ~'^[0-9a-f]{64}$'
        AND (p_value.record_revenue).expected_invoice_reconciliation_digest
          ~'^[0-9a-f]{64}$'
        AND cardinality((p_value.record_revenue).rows)>0
        AND NOT EXISTS (
          SELECT 1 FROM unnest((p_value.record_revenue).rows) value
          WHERE value IS NULL
            OR ops.economics_closed_composite_required_v1(
              to_jsonb(value),'{}'::text[]
            ) IS NOT TRUE
            OR value.invoice_id<>(p_value.record_revenue).expected_invoice_id
            OR value.invoice_line_id IS NULL
            OR value.invoice_line_digest!~'^[0-9a-f]{64}$'
            OR NOT ops.economics_finite_numeric_v1(value.amount)
        )
      ),false);
    WHEN 'recordAccountingCorrection' THEN
      RETURN COALESCE((
        p_value.record_accounting_correction IS NOT NULL
        AND cardinality((p_value.record_accounting_correction).rows)>0
        AND NOT EXISTS (
          SELECT 1 FROM unnest(
            (p_value.record_accounting_correction).rows
          ) value WHERE value IS NULL
            OR ops.economics_closed_composite_required_v1(
              to_jsonb(value),
              ARRAY[
                'organization_id','supersedes_correction_id',
                'reverses_correction_id','predecessor_correction_digest',
                'target_cost_event_id','target_cost_allocation_id',
                'target_invoice_fact_id','target_invoice_line_fact_id',
                'target_revenue_fact_id','proposed_by','approver_id',
                'decision_digest','expected_head_id','expected_head_revision',
                'expected_head_digest'
              ]
            ) IS NOT TRUE
            OR num_nonnulls(
              value.proposed_by,value.approver_id,value.decision_digest
            )<>0
            OR NOT ops.economics_finite_numeric_v1(value.amount)
            OR NOT ops.economics_finite_numeric_v1(value.effective_delta)
            OR NOT ops.economics_finite_numeric_v1(
              value.expected_resulting_effective_amount
            )
            OR num_nonnulls(
              value.target_cost_event_id,value.target_cost_allocation_id,
              value.target_invoice_fact_id,value.target_invoice_line_fact_id,
              value.target_revenue_fact_id
            )<>1
            OR value.target_fact_id IS DISTINCT FROM CASE value.target_fact_kind
              WHEN 'COST_EVENT' THEN value.target_cost_event_id
              WHEN 'COST_ALLOCATION' THEN value.target_cost_allocation_id
              WHEN 'INVOICE_FACT' THEN value.target_invoice_fact_id
              WHEN 'INVOICE_LINE_FACT' THEN value.target_invoice_line_fact_id
              WHEN 'REVENUE_FACT' THEN value.target_revenue_fact_id
              ELSE NULL
            END
        )
      ),false);
    WHEN 'recordCashApplication' THEN
      RETURN COALESCE((
        p_value.record_cash_application IS NOT NULL
        AND cardinality((p_value.record_cash_application).rows)>0
        AND NOT EXISTS (
          SELECT 1 FROM unnest((p_value.record_cash_application).rows) value
          WHERE value IS NULL
            OR ops.economics_closed_composite_required_v1(
              to_jsonb(value),
              ARRAY[
                'supersedes_fact_id','predecessor_fact_digest',
                'expected_head_id','expected_head_revision',
                'expected_head_digest'
              ]
            ) IS NOT TRUE
            OR value.source_kind NOT IN ('BANK_TRANSFER','PG_SETTLEMENT')
            OR NOT ops.economics_finite_numeric_v1(
              value.source_settlement_amount
            )
            OR NOT ops.economics_finite_numeric_v1(value.applied_amount)
        )
      ),false);
    WHEN 'recordTaxInvoiceIssuance' THEN
      RETURN COALESCE((
        p_value.record_tax_invoice_issuance IS NOT NULL
        AND cardinality((p_value.record_tax_invoice_issuance).rows)>0
        AND NOT EXISTS (
          SELECT 1 FROM unnest(
            (p_value.record_tax_invoice_issuance).rows
          ) value WHERE value IS NULL
            OR ops.economics_closed_composite_required_v1(
              to_jsonb(value),
              ARRAY[
                'supersedes_receipt_id','predecessor_receipt_digest',
                'approval_number_hmac','approval_number_hmac_key_version',
                'asp_receipt_reference_hmac',
                'asp_receipt_reference_hmac_key_version',
                'asp_receipt_digest','issued_at','cancelled_at',
                'expected_head_id','expected_head_revision',
                'expected_head_digest'
              ]
            ) IS NOT TRUE
            OR NOT ops.economics_finite_numeric_v1(value.taxable_amount)
            OR NOT ops.economics_finite_numeric_v1(value.tax_amount)
        )
      ),false);
    WHEN 'recordCollectionFailure' THEN
      v_collection:=p_value.record_collection_failure;
      IF v_collection IS NULL OR v_collection.task_assignee_id IS NULL
        OR v_collection.task_due_at IS NULL
        OR v_collection.reason_code IS NULL
        OR btrim(v_collection.reason_code)=''
        OR v_collection.reason_digest !~ '^[0-9a-f]{64}$' THEN
        RETURN false;
      END IF;
      IF NOT ops.economics_closed_composite_required_v1(
        to_jsonb(v_collection),
        ARRAY[
          'provider_charge_attempt_id','provider_charge_attempt_digest',
          'provider_fetch_digest','invoice_fact_id','invoice_fact_digest',
          'invoice_reconciliation_digest','expected_invoice_revision',
          'signed_evidence_segment_id','signed_evidence_segment_digest'
        ]
      ) THEN
        RETURN false;
      END IF;
      RETURN COALESCE((
        v_collection.authority_kind='PROVIDER_FETCH_CONFIRMED'
        AND num_nonnulls(
          v_collection.provider_charge_attempt_id,
          v_collection.provider_charge_attempt_digest,
          v_collection.provider_fetch_digest
        )=3
        AND num_nonnulls(
          v_collection.invoice_fact_id,v_collection.invoice_fact_digest,
          v_collection.invoice_reconciliation_digest,
          v_collection.expected_invoice_revision,
          v_collection.signed_evidence_segment_id,
          v_collection.signed_evidence_segment_digest
        )=0
      ) OR (
        v_collection.authority_kind='BANK_RETURN_CONFIRMED'
        AND num_nonnulls(
          v_collection.invoice_fact_id,v_collection.invoice_fact_digest,
          v_collection.invoice_reconciliation_digest,
          v_collection.expected_invoice_revision,
          v_collection.signed_evidence_segment_id,
          v_collection.signed_evidence_segment_digest
        )=6
        AND num_nonnulls(
          v_collection.provider_charge_attempt_id,
          v_collection.provider_charge_attempt_digest,
          v_collection.provider_fetch_digest
        )=0
      ),false);
    ELSE
      RETURN false;
  END CASE;
END
$$;
ALTER FUNCTION ops.economics_import_operation_v1_is_valid(
  ops.economics_import_operation_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_import_operation_v1_is_valid(
  ops.economics_import_operation_v1
) FROM PUBLIC;

REVOKE ALL ON TYPE
  ops.economics_source_resolution_v1,
  ops.economics_acquisition_source_import_v1,
  ops.economics_fx_rate_append_v1,
  ops.economics_fx_rate_source_import_v1,
  ops.economics_discount_append_v1,
  ops.economics_discount_source_import_v1,
  ops.economics_qualification_import_v1,
  ops.economics_cost_period_import_v1,
  ops.economics_cost_line_import_v1,
  ops.economics_cost_close_import_v1,
  ops.economics_tariff_import_v1,
  ops.economics_offer_capability_import_v1,
  ops.economics_contract_import_v1,
  ops.economics_usage_receipt_import_v1,
  ops.economics_usage_fact_import_v1,
  ops.economics_usage_window_import_v1,
  ops.economics_invoice_header_import_v1,
  ops.economics_invoice_line_import_v1,
  ops.economics_invoice_membership_import_v1,
  ops.economics_invoice_import_v1,
  ops.economics_revenue_row_import_v1,
  ops.economics_revenue_import_v1,
  ops.economics_accounting_correction_import_v1,
  ops.economics_accounting_corrections_import_v1,
  ops.economics_cash_application_import_v1,
  ops.economics_cash_applications_import_v1,
  ops.economics_tax_invoice_import_v1,
  ops.economics_tax_invoices_import_v1,
  ops.economics_collection_failure_import_v1,
  ops.economics_import_operation_v1,
  ops.economics_import_result_row_v1,
  ops.economics_import_apply_receipt_v1
FROM PUBLIC;

CREATE TABLE ops.action_approval_economics_import_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  approval_digest char(64) NOT NULL,
  content_digest char(64) NOT NULL,
  operation_id text NOT NULL,
  operation_value ops.economics_import_operation_v1 NOT NULL,
  operation_canonical bytea NOT NULL,
  operation_digest char(64) NOT NULL,
  source_evidence_segment_ids uuid[] NOT NULL,
  source_evidence_digests char(64)[] NOT NULL,
  source_evidence_set_digest char(64) NOT NULL,
  import_policy_digest char(64) NOT NULL,
  as_of timestamptz NOT NULL,
  creator_actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  proposer_capability_set_digest char(64) NOT NULL,
  reviewer_capability_set_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT action_approval_economics_import_details_pk
    PRIMARY KEY (proposal_id,proposal_version),
  CONSTRAINT action_approval_economics_import_details_binding_uq UNIQUE (
    proposal_id,proposal_version,detail_kind,action_detail_digest
  ),
  CONSTRAINT action_approval_economics_import_details_approval_uq UNIQUE (
    proposal_id,proposal_version,approval_digest,operation_digest
  ),
  CONSTRAINT action_approval_economics_import_details_kind_ck
    CHECK (detail_kind='ECONOMICS_IMPORT'),
  CONSTRAINT action_approval_economics_import_details_operation_ck CHECK (
    operation_id IN (
      'recordCommercialQualification','importCostAllocationClose',
      'createTariffVersion','recordCommercialContractPeriod',
      'recordUsageWindow','recordInvoice','recordRevenue',
      'recordAccountingCorrection','recordCashApplication',
      'recordTaxInvoiceIssuance','recordCollectionFailure'
    )
  ),
  CONSTRAINT action_approval_economics_import_details_digest_ck CHECK (
    action_detail_digest ~ '^[0-9a-f]{64}$'
    AND approval_digest ~ '^[0-9a-f]{64}$'
    AND content_digest ~ '^[0-9a-f]{64}$'
    AND operation_digest ~ '^[0-9a-f]{64}$'
    AND source_evidence_set_digest ~ '^[0-9a-f]{64}$'
    AND import_policy_digest ~ '^[0-9a-f]{64}$'
    AND proposer_capability_set_digest ~ '^[0-9a-f]{64}$'
    AND reviewer_capability_set_digest ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT action_approval_economics_import_details_evidence_ck CHECK (
    cardinality(source_evidence_segment_ids)
      = cardinality(source_evidence_digests)
    AND cardinality(source_evidence_segment_ids) BETWEEN 1 AND 1000
    AND ops.economics_uuid_array_is_sorted_unique_v1(
      source_evidence_segment_ids
    )
    AND ops.sha256_text_array_is_valid_v1(source_evidence_digests::text[])
  ),
  CONSTRAINT action_approval_economics_import_details_canonical_ck CHECK (
    octet_length(detail_binding_canonical)>0
    AND ops.economics_import_operation_v1_is_valid(operation_value) IS TRUE
    AND (operation_value).import_kind=operation_id
    AND operation_canonical=ops.canonical_jsonb_v1(to_jsonb(operation_value))
    AND operation_digest=encode(
      extensions.digest(operation_canonical,'sha256'),'hex'
    )
  ),
  CONSTRAINT action_approval_economics_import_details_version_fk FOREIGN KEY (
    proposal_id,proposal_version,detail_kind,action_detail_digest
  ) REFERENCES ops.action_proposal_versions(
    proposal_id,version,action_detail_kind,action_detail_digest
  ) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT action_approval_economics_import_details_approval_fk FOREIGN KEY (
    proposal_id,proposal_version,approval_digest
  ) REFERENCES ops.action_proposal_versions(
    proposal_id,version,approval_digest
  ) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
);
ALTER TABLE ops.action_approval_economics_import_details OWNER TO gurine_migrator;
REVOKE ALL ON ops.action_approval_economics_import_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_economics_import_details FROM
  gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_public_projector,gurine_notification_worker,gurine_submission_api,
  gurine_auditor,gurine_billing_gateway;
CREATE TRIGGER ops_action_approval_economics_import_details_immutable
  BEFORE UPDATE OR DELETE ON ops.action_approval_economics_import_details
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

-- 0029 omitted the invoice record digest even though its frozen writer ABI and
-- the cash/tax fence both require one.  There is no authority to invent a
-- digest for a historical row, so the additive closure aborts if such a row
-- exists instead of guessing a backfill.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM ops.invoice_facts) THEN
    RAISE EXCEPTION 'R6E_INVOICE_RECORD_DIGEST_BACKFILL_AUTHORITY_REQUIRED'
      USING ERRCODE='55000';
  END IF;
END
$$;
ALTER TABLE ops.invoice_facts ADD COLUMN record_digest char(64);
ALTER TABLE ops.invoice_facts ALTER COLUMN record_digest SET NOT NULL;
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_record_digest_uq
  UNIQUE (record_digest);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_record_reference_uq
  UNIQUE (id,record_digest);
ALTER TABLE ops.invoice_facts ADD CONSTRAINT invoice_facts_record_digest_ck
  CHECK (record_digest ~ '^[0-9a-f]{64}$');

-- Cash is independent from invoice, revenue, entitlement and product value.
-- The exact invoice identity/digest is therefore carried on every application.
CREATE TABLE ops.cash_application_facts (
  id uuid PRIMARY KEY,
  root_fact_id uuid NOT NULL,
  revision bigint NOT NULL,
  fact_effect text NOT NULL,
  supersedes_fact_id uuid,
  predecessor_fact_digest char(64),
  invoice_fact_id uuid NOT NULL,
  invoice_fact_digest char(64) NOT NULL,
  invoice_reconciliation_digest char(64) NOT NULL,
  source_kind text NOT NULL,
  source_system_id text NOT NULL,
  source_settlement_identity_hmac char(64) NOT NULL,
  source_settlement_hmac_key_version text NOT NULL,
  source_settlement_amount numeric(24,6) NOT NULL,
  applied_amount numeric(24,6) NOT NULL,
  currency char(3) NOT NULL,
  source_record_digest char(64) NOT NULL,
  source_signature_digest char(64) NOT NULL,
  import_receipt_digest char(64) NOT NULL,
  applied_at timestamptz NOT NULL,
  fact_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT cash_application_root_revision_uq UNIQUE (root_fact_id,revision),
  CONSTRAINT cash_application_fact_digest_uq UNIQUE (fact_digest),
  CONSTRAINT cash_application_reference_uq UNIQUE (id,fact_digest),
  CONSTRAINT cash_application_source_identity_uq UNIQUE (
    source_system_id,source_settlement_identity_hmac,revision
  ),
  CONSTRAINT cash_application_chain_ck CHECK (
    revision>0 AND (
      fact_effect='ORIGINAL' AND revision=1 AND root_fact_id=id
      AND supersedes_fact_id IS NULL AND predecessor_fact_digest IS NULL
      OR fact_effect='REVERSAL' AND revision>1 AND root_fact_id<>id
      AND supersedes_fact_id IS NOT NULL
      AND predecessor_fact_digest IS NOT NULL
    )
  ),
  CONSTRAINT cash_application_shape_ck CHECK (
    source_kind IN ('BANK_TRANSFER','PG_SETTLEMENT')
    AND length(btrim(source_system_id)) BETWEEN 1 AND 128
    AND length(btrim(source_settlement_hmac_key_version)) BETWEEN 1 AND 100
    AND source_settlement_amount>0 AND applied_amount>0
    AND applied_amount<=source_settlement_amount
    AND currency ~ '^[A-Z]{3}$'
  ),
  CONSTRAINT cash_application_digest_ck CHECK (
    (predecessor_fact_digest IS NULL
      OR predecessor_fact_digest ~ '^[0-9a-f]{64}$')
    AND invoice_fact_digest ~ '^[0-9a-f]{64}$'
    AND invoice_reconciliation_digest ~ '^[0-9a-f]{64}$'
    AND source_settlement_identity_hmac ~ '^[0-9a-f]{64}$'
    AND source_record_digest ~ '^[0-9a-f]{64}$'
    AND source_signature_digest ~ '^[0-9a-f]{64}$'
    AND import_receipt_digest ~ '^[0-9a-f]{64}$'
    AND fact_digest ~ '^[0-9a-f]{64}$'
  )
);
ALTER TABLE ops.cash_application_facts OWNER TO gurine_migrator;
CREATE UNIQUE INDEX cash_application_one_successor_uq
  ON ops.cash_application_facts(supersedes_fact_id)
  WHERE supersedes_fact_id IS NOT NULL;
CREATE INDEX cash_application_invoice_fk_idx
  ON ops.cash_application_facts(invoice_fact_id,invoice_fact_digest,id);
ALTER TABLE ops.cash_application_facts ADD CONSTRAINT cash_application_root_fk
  FOREIGN KEY (root_fact_id) REFERENCES ops.cash_application_facts(id)
  ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.cash_application_facts ADD CONSTRAINT cash_application_supersedes_fk
  FOREIGN KEY (supersedes_fact_id,predecessor_fact_digest)
  REFERENCES ops.cash_application_facts(id,fact_digest)
  MATCH FULL ON DELETE RESTRICT;
ALTER TABLE ops.cash_application_facts ADD CONSTRAINT cash_application_invoice_fk
  FOREIGN KEY (invoice_fact_id,invoice_fact_digest)
  REFERENCES ops.invoice_facts(id,record_digest) ON DELETE RESTRICT;

-- ASP integration is intentionally absent.  PENDING_ASP can be imported, but
-- a confirmed issuance requires both approval-number HMAC and ASP receipt.
CREATE TABLE ops.tax_invoice_issuance_receipts (
  id uuid PRIMARY KEY,
  root_receipt_id uuid NOT NULL,
  revision bigint NOT NULL,
  receipt_effect text NOT NULL,
  supersedes_receipt_id uuid,
  predecessor_receipt_digest char(64),
  invoice_fact_id uuid NOT NULL,
  invoice_fact_digest char(64) NOT NULL,
  invoice_reconciliation_digest char(64) NOT NULL,
  taxable_amount numeric(24,6) NOT NULL,
  tax_amount numeric(24,6) NOT NULL,
  currency char(3) NOT NULL,
  issuance_state text NOT NULL,
  approval_number_hmac char(64),
  approval_number_hmac_key_version text,
  asp_receipt_reference_hmac char(64),
  asp_receipt_reference_hmac_key_version text,
  asp_receipt_digest char(64),
  source_system_id text NOT NULL,
  source_record_digest char(64) NOT NULL,
  source_signature_digest char(64) NOT NULL,
  import_receipt_digest char(64) NOT NULL,
  issued_at timestamptz,
  cancelled_at timestamptz,
  receipt_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT tax_invoice_root_revision_uq UNIQUE (root_receipt_id,revision),
  CONSTRAINT tax_invoice_receipt_digest_uq UNIQUE (receipt_digest),
  CONSTRAINT tax_invoice_reference_uq UNIQUE (id,receipt_digest),
  CONSTRAINT tax_invoice_chain_ck CHECK (
    revision>0 AND (
      receipt_effect='ORIGINAL' AND revision=1 AND root_receipt_id=id
      AND supersedes_receipt_id IS NULL AND predecessor_receipt_digest IS NULL
      OR receipt_effect='REPLACEMENT' AND revision>1 AND root_receipt_id<>id
      AND supersedes_receipt_id IS NOT NULL
      AND predecessor_receipt_digest IS NOT NULL
    )
  ),
  CONSTRAINT tax_invoice_state_ck CHECK (
    issuance_state IN (
      'PENDING_ASP','ISSUED_CONFIRMED','CANCELLED_CONFIRMED'
    )
    AND (
      issuance_state='PENDING_ASP'
      AND approval_number_hmac IS NULL
      AND approval_number_hmac_key_version IS NULL
      AND asp_receipt_reference_hmac IS NULL
      AND asp_receipt_reference_hmac_key_version IS NULL
      AND asp_receipt_digest IS NULL
      AND issued_at IS NULL AND cancelled_at IS NULL
      OR issuance_state='ISSUED_CONFIRMED'
      AND approval_number_hmac IS NOT NULL
      AND approval_number_hmac_key_version IS NOT NULL
      AND asp_receipt_reference_hmac IS NOT NULL
      AND asp_receipt_reference_hmac_key_version IS NOT NULL
      AND asp_receipt_digest IS NOT NULL
      AND issued_at IS NOT NULL AND cancelled_at IS NULL
      OR issuance_state='CANCELLED_CONFIRMED'
      AND approval_number_hmac IS NOT NULL
      AND approval_number_hmac_key_version IS NOT NULL
      AND asp_receipt_reference_hmac IS NOT NULL
      AND asp_receipt_reference_hmac_key_version IS NOT NULL
      AND asp_receipt_digest IS NOT NULL
      AND issued_at IS NOT NULL AND cancelled_at IS NOT NULL
      AND cancelled_at>=issued_at
    )
    AND taxable_amount>=0 AND tax_amount>=0 AND currency ~ '^[A-Z]{3}$'
    AND length(btrim(source_system_id)) BETWEEN 1 AND 128
  ),
  CONSTRAINT tax_invoice_digest_ck CHECK (
    (predecessor_receipt_digest IS NULL
      OR predecessor_receipt_digest ~ '^[0-9a-f]{64}$')
    AND invoice_fact_digest ~ '^[0-9a-f]{64}$'
    AND invoice_reconciliation_digest ~ '^[0-9a-f]{64}$'
    AND (approval_number_hmac IS NULL
      OR approval_number_hmac ~ '^[0-9a-f]{64}$')
    AND (asp_receipt_reference_hmac IS NULL
      OR asp_receipt_reference_hmac ~ '^[0-9a-f]{64}$')
    AND (asp_receipt_digest IS NULL
      OR asp_receipt_digest ~ '^[0-9a-f]{64}$')
    AND source_record_digest ~ '^[0-9a-f]{64}$'
    AND source_signature_digest ~ '^[0-9a-f]{64}$'
    AND import_receipt_digest ~ '^[0-9a-f]{64}$'
    AND receipt_digest ~ '^[0-9a-f]{64}$'
  )
);
ALTER TABLE ops.tax_invoice_issuance_receipts OWNER TO gurine_migrator;
CREATE UNIQUE INDEX tax_invoice_one_successor_uq
  ON ops.tax_invoice_issuance_receipts(supersedes_receipt_id)
  WHERE supersedes_receipt_id IS NOT NULL;
ALTER TABLE ops.tax_invoice_issuance_receipts ADD CONSTRAINT tax_invoice_root_fk
  FOREIGN KEY (root_receipt_id)
  REFERENCES ops.tax_invoice_issuance_receipts(id)
  ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.tax_invoice_issuance_receipts ADD CONSTRAINT tax_invoice_supersedes_fk
  FOREIGN KEY (supersedes_receipt_id,predecessor_receipt_digest)
  REFERENCES ops.tax_invoice_issuance_receipts(id,receipt_digest)
  MATCH FULL ON DELETE RESTRICT;
ALTER TABLE ops.tax_invoice_issuance_receipts ADD CONSTRAINT tax_invoice_invoice_fk
  FOREIGN KEY (invoice_fact_id,invoice_fact_digest)
  REFERENCES ops.invoice_facts(id,record_digest) ON DELETE RESTRICT;

-- Provider work is always claimed and committed before any fixture transport
-- is invoked. Raw provider keys, order IDs, event IDs, bodies, headers and
-- signatures never cross this boundary; only keyed HMACs and one-way digests do.
CREATE TABLE ops.payment_method_bindings (
  id uuid PRIMARY KEY,
  root_binding_id uuid NOT NULL,
  revision bigint NOT NULL,
  binding_effect text NOT NULL,
  supersedes_binding_id uuid,
  predecessor_record_digest char(64),
  donation_intent_id uuid NOT NULL,
  request_id uuid NOT NULL,
  request_digest char(64) NOT NULL,
  deployment_id uuid NOT NULL,
  environment text NOT NULL,
  fixture_authority text NOT NULL,
  provider text NOT NULL,
  merchant_account_hmac char(64) NOT NULL,
  merchant_hmac_key_version text NOT NULL,
  donor_hmac char(64) NOT NULL,
  donor_group_hmac char(64) NOT NULL,
  donor_hmac_key_version text NOT NULL,
  provider_issue_idempotency_key_hmac char(64) NOT NULL,
  provider_issue_idempotency_hmac_key_version text NOT NULL,
  reserved_job_id uuid NOT NULL,
  billing_key_secret_reference text,
  billing_key_hmac char(64),
  billing_key_hmac_key_version text,
  credential_use_policy text NOT NULL,
  schedule_kind text NOT NULL,
  schedule_id uuid NOT NULL,
  schedule_version bigint NOT NULL,
  schedule_digest char(64) NOT NULL,
  offer_version_id uuid NOT NULL,
  offer_digest char(64) NOT NULL,
  tier_id uuid NOT NULL,
  first_charge_at timestamptz NOT NULL,
  mandate_amount numeric(24,6) NOT NULL,
  currency char(3) NOT NULL,
  consent_receipt_digest char(64) NOT NULL,
  mandate_digest char(64) NOT NULL,
  binding_state text NOT NULL,
  claim_digest char(64) NOT NULL,
  provider_issue_request_digest char(64),
  provider_issue_response_digest char(64),
  provider_issue_http_status integer,
  completion_request_digest char(64),
  queued_job_id uuid,
  queued_receipt_digest char(64),
  failure_code text,
  failure_evidence_digest char(64),
  claimed_at timestamptz NOT NULL,
  bound_at timestamptz,
  revoked_at timestamptz,
  terminal_at timestamptz,
  audit_event_id uuid NOT NULL,
  record_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT payment_method_binding_root_revision_uq
    UNIQUE (root_binding_id,revision),
  CONSTRAINT payment_method_binding_request_revision_uq
    UNIQUE (request_id,revision),
  CONSTRAINT payment_method_binding_intent_revision_uq
    UNIQUE (donation_intent_id,revision),
  CONSTRAINT payment_method_binding_reserved_job_revision_uq
    UNIQUE (reserved_job_id,revision),
  CONSTRAINT payment_method_binding_record_digest_uq UNIQUE (record_digest),
  CONSTRAINT payment_method_binding_reference_uq UNIQUE (id,record_digest),
  CONSTRAINT payment_method_binding_chain_ck CHECK (
    revision>0 AND (
      binding_effect='ORIGINAL' AND revision=1 AND root_binding_id=id
      AND supersedes_binding_id IS NULL AND predecessor_record_digest IS NULL
      AND binding_state='PENDING_PROVIDER'
      OR binding_effect IN ('ACTIVATION','FAILURE','REVOCATION')
      AND revision>1 AND root_binding_id<>id
      AND supersedes_binding_id IS NOT NULL
      AND predecessor_record_digest IS NOT NULL
      AND (binding_effect,binding_state) IN (
        ('ACTIVATION','ACTIVE'),('FAILURE','FAILED'),('REVOCATION','REVOKED')
      )
    )
  ),
  CONSTRAINT payment_method_binding_state_ck CHECK (
    provider IN ('TOSS_PAYMENTS','KAKAO_PAY','STRIPE')
    AND environment='TEST'
    AND fixture_authority='TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY'
    AND credential_use_policy IN ('SINGLE_CHARGE','RECURRING')
    AND schedule_kind IN ('ONE_TIME','MONTHLY')
    AND (credential_use_policy,schedule_kind) IN (
      ('SINGLE_CHARGE','ONE_TIME'),('RECURRING','MONTHLY')
    )
    AND schedule_version>0 AND first_charge_at>=claimed_at
    AND mandate_amount>0 AND trunc(mandate_amount)=mandate_amount
    AND currency='KRW'
    AND length(btrim(merchant_hmac_key_version)) BETWEEN 1 AND 100
    AND length(btrim(donor_hmac_key_version)) BETWEEN 1 AND 100
    AND length(btrim(provider_issue_idempotency_hmac_key_version)) BETWEEN 1 AND 100
    AND (
      binding_state='PENDING_PROVIDER'
      AND billing_key_secret_reference IS NULL AND billing_key_hmac IS NULL
      AND billing_key_hmac_key_version IS NULL
      AND provider_issue_request_digest IS NULL
      AND provider_issue_response_digest IS NULL
      AND provider_issue_http_status IS NULL
      AND completion_request_digest IS NULL
      AND queued_job_id IS NULL AND queued_receipt_digest IS NULL
      AND failure_code IS NULL AND failure_evidence_digest IS NULL
      AND bound_at IS NULL AND revoked_at IS NULL AND terminal_at IS NULL
      OR binding_state='ACTIVE'
      AND ops.secret_reference_is_version_pinned(billing_key_secret_reference)
      AND billing_key_hmac IS NOT NULL
      AND billing_key_hmac_key_version IS NOT NULL
      AND provider_issue_request_digest IS NOT NULL
      AND provider_issue_response_digest IS NOT NULL
      AND provider_issue_http_status BETWEEN 200 AND 299
      AND completion_request_digest IS NOT NULL
      AND queued_job_id IS NOT NULL AND queued_receipt_digest IS NOT NULL
      AND failure_code IS NULL AND failure_evidence_digest IS NULL
      AND bound_at IS NOT NULL AND bound_at>=claimed_at
      AND revoked_at IS NULL AND terminal_at=bound_at
      OR binding_state='FAILED'
      AND billing_key_secret_reference IS NULL AND billing_key_hmac IS NULL
      AND billing_key_hmac_key_version IS NULL
      AND provider_issue_request_digest IS NULL
      AND provider_issue_response_digest IS NULL
      AND provider_issue_http_status IS NULL
      AND completion_request_digest IS NULL
      AND queued_job_id IS NULL AND queued_receipt_digest IS NULL
      AND length(btrim(failure_code)) BETWEEN 1 AND 100
      AND failure_evidence_digest IS NOT NULL
      AND bound_at IS NULL AND revoked_at IS NULL
      AND terminal_at IS NOT NULL AND terminal_at>=claimed_at
      OR binding_state='REVOKED'
      AND billing_key_secret_reference IS NOT NULL AND billing_key_hmac IS NOT NULL
      AND billing_key_hmac_key_version IS NOT NULL
      AND bound_at IS NOT NULL AND revoked_at IS NOT NULL
      AND revoked_at>=bound_at AND terminal_at=revoked_at
    )
  ),
  CONSTRAINT payment_method_binding_digest_ck CHECK (
    (predecessor_record_digest IS NULL
      OR predecessor_record_digest ~ '^[0-9a-f]{64}$')
    AND request_digest ~ '^[0-9a-f]{64}$'
    AND merchant_account_hmac ~ '^[0-9a-f]{64}$'
    AND donor_hmac ~ '^[0-9a-f]{64}$'
    AND donor_group_hmac ~ '^[0-9a-f]{64}$'
    AND provider_issue_idempotency_key_hmac ~ '^[0-9a-f]{64}$'
    AND (billing_key_hmac IS NULL OR billing_key_hmac ~ '^[0-9a-f]{64}$')
    AND consent_receipt_digest ~ '^[0-9a-f]{64}$'
    AND mandate_digest ~ '^[0-9a-f]{64}$'
    AND schedule_digest ~ '^[0-9a-f]{64}$'
    AND offer_digest ~ '^[0-9a-f]{64}$'
    AND claim_digest ~ '^[0-9a-f]{64}$'
    AND (provider_issue_request_digest IS NULL
      OR provider_issue_request_digest ~ '^[0-9a-f]{64}$')
    AND (provider_issue_response_digest IS NULL
      OR provider_issue_response_digest ~ '^[0-9a-f]{64}$')
    AND (completion_request_digest IS NULL
      OR completion_request_digest ~ '^[0-9a-f]{64}$')
    AND (queued_receipt_digest IS NULL
      OR queued_receipt_digest ~ '^[0-9a-f]{64}$')
    AND (failure_evidence_digest IS NULL
      OR failure_evidence_digest ~ '^[0-9a-f]{64}$')
    AND record_digest ~ '^[0-9a-f]{64}$'
  )
);
ALTER TABLE ops.payment_method_bindings OWNER TO gurine_migrator;
CREATE UNIQUE INDEX payment_method_binding_one_successor_uq
  ON ops.payment_method_bindings(supersedes_binding_id)
  WHERE supersedes_binding_id IS NOT NULL;
CREATE UNIQUE INDEX payment_method_binding_request_root_uq
  ON ops.payment_method_bindings(request_id) WHERE revision=1;
CREATE UNIQUE INDEX payment_method_binding_active_uq
  ON ops.payment_method_bindings(
    provider,merchant_account_hmac,donor_hmac,schedule_kind
  ) WHERE binding_effect='ORIGINAL';
CREATE UNIQUE INDEX payment_method_binding_schedule_offer_uq
  ON ops.payment_method_bindings(
    schedule_id,schedule_version,offer_version_id,tier_id,revision
  );
ALTER TABLE ops.payment_method_bindings ADD CONSTRAINT payment_method_binding_root_fk
  FOREIGN KEY (root_binding_id) REFERENCES ops.payment_method_bindings(id)
  ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.payment_method_bindings ADD CONSTRAINT payment_method_binding_supersedes_fk
  FOREIGN KEY (supersedes_binding_id,predecessor_record_digest)
  REFERENCES ops.payment_method_bindings(id,record_digest)
  MATCH FULL ON DELETE RESTRICT;
ALTER TABLE ops.payment_method_bindings ADD CONSTRAINT payment_method_binding_job_fk
  FOREIGN KEY (queued_job_id) REFERENCES ops.jobs(id)
  ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE ops.payment_charge_attempts (
  id uuid PRIMARY KEY,
  root_attempt_id uuid NOT NULL,
  observation_version bigint NOT NULL,
  observation_effect text NOT NULL,
  supersedes_attempt_id uuid,
  predecessor_record_digest char(64),
  payment_method_binding_id uuid NOT NULL,
  payment_method_binding_digest char(64) NOT NULL,
  job_id uuid NOT NULL,
  worker_id text NOT NULL,
  job_lease_token_digest char(64) NOT NULL,
  job_fencing_token bigint NOT NULL,
  job_binding_digest char(64) NOT NULL,
  logical_charge_id uuid NOT NULL,
  charge_idempotency_key_sha256 char(64) NOT NULL,
  provider text NOT NULL,
  provider_idempotency_key_hmac char(64) NOT NULL,
  provider_idempotency_hmac_key_version text NOT NULL,
  merchant_order_id_hmac char(64) NOT NULL,
  merchant_order_hmac_key_version text NOT NULL,
  merchant_order_id_digest char(64) NOT NULL,
  expected_provider_payment_id_digest char(64) NOT NULL,
  provider_locator_authority text NOT NULL,
  provider_payment_id_digest char(64),
  provider_observed_state text,
  purpose text NOT NULL,
  producer_operation_id text NOT NULL,
  amount numeric(24,6) NOT NULL,
  currency char(3) NOT NULL,
  attempt_state text NOT NULL,
  request_digest char(64) NOT NULL,
  provider_transport_request_digest char(64),
  provider_transport_response_digest char(64),
  provider_fetch_digest char(64),
  fixture_authority text,
  test_payment_outcome_config_digest char(64),
  completion_request_digest char(64),
  terminal_authority text,
  local_failure_code text,
  local_failure_evidence_digest char(64),
  reconciliation_reason text,
  reconciliation_evidence_digest char(64),
  requested_at timestamptz NOT NULL,
  provider_observed_at timestamptz,
  terminal_at timestamptz,
  audit_event_id uuid NOT NULL,
  record_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT payment_charge_attempt_root_version_uq
    UNIQUE (root_attempt_id,observation_version),
  CONSTRAINT payment_charge_attempt_job_version_uq
    UNIQUE (job_id,observation_version),
  CONSTRAINT payment_charge_attempt_record_digest_uq UNIQUE (record_digest),
  CONSTRAINT payment_charge_attempt_row_reference_uq UNIQUE (id,record_digest),
  CONSTRAINT payment_charge_attempt_reference_uq
    UNIQUE (root_attempt_id,record_digest),
  CONSTRAINT payment_charge_attempt_chain_ck CHECK (
    observation_version>0 AND (
      observation_effect='ORIGINAL' AND observation_version=1
      AND root_attempt_id=id AND supersedes_attempt_id IS NULL
      AND predecessor_record_digest IS NULL AND attempt_state='REQUESTED'
      OR observation_effect IN (
        'PROVIDER_ACCEPTANCE','OBSERVATION','LOCAL_REJECTION',
        'RECONCILIATION'
      ) AND observation_version>1
      AND root_attempt_id<>id AND supersedes_attempt_id IS NOT NULL
      AND predecessor_record_digest IS NOT NULL
      AND attempt_state IN (
        'PROVIDER_ACCEPTED','RECONCILIATION_REQUIRED','SUCCEEDED','FAILED',
        'REFUNDED'
      )
    )
  ),
  CONSTRAINT payment_charge_attempt_state_ck CHECK (
    provider IN ('TOSS_PAYMENTS','KAKAO_PAY','STRIPE')
    AND purpose='DONATION'
    AND producer_operation_id IN (
      'private.ExecuteDonationCharge','private.ReceivePaymentWebhook'
    )
    AND amount>0 AND trunc(amount)=amount AND currency='KRW'
    AND job_fencing_token>0
    AND length(btrim(worker_id)) BETWEEN 1 AND 200
    AND length(btrim(provider_idempotency_hmac_key_version)) BETWEEN 1 AND 100
    AND length(btrim(merchant_order_hmac_key_version)) BETWEEN 1 AND 100
    AND provider_locator_authority='TEST_FIXTURE_DERIVED_EXPECTATION'
    AND (
      attempt_state='REQUESTED'
      AND producer_operation_id='private.ExecuteDonationCharge'
      AND provider_payment_id_digest IS NULL
      AND provider_observed_state IS NULL
      AND provider_transport_request_digest IS NULL
      AND provider_transport_response_digest IS NULL
      AND provider_fetch_digest IS NULL
      AND fixture_authority IS NULL
      AND test_payment_outcome_config_digest IS NULL
      AND completion_request_digest IS NULL
      AND terminal_authority IS NULL
      AND local_failure_code IS NULL
      AND local_failure_evidence_digest IS NULL
      AND reconciliation_reason IS NULL
      AND reconciliation_evidence_digest IS NULL
      AND provider_observed_at IS NULL AND terminal_at IS NULL
      OR attempt_state='PROVIDER_ACCEPTED'
      AND producer_operation_id='private.ExecuteDonationCharge'
      AND provider_payment_id_digest=expected_provider_payment_id_digest
      AND provider_observed_state='PENDING'
      AND provider_transport_request_digest IS NOT NULL
      AND provider_transport_response_digest IS NOT NULL
      AND provider_fetch_digest IS NULL
      AND fixture_authority='TEST_FIXTURE'
      AND test_payment_outcome_config_digest IS NOT NULL
      AND completion_request_digest IS NOT NULL
      AND terminal_authority IS NULL
      AND local_failure_code IS NULL
      AND local_failure_evidence_digest IS NULL
      AND reconciliation_reason IS NULL
      AND reconciliation_evidence_digest IS NULL
      AND provider_observed_at IS NULL AND terminal_at IS NULL
      OR attempt_state='RECONCILIATION_REQUIRED'
      AND reconciliation_reason<>'PARTIAL_REFUND_AMOUNT_UNAVAILABLE'
      AND provider_payment_id_digest IS NULL
      AND provider_observed_state IS NULL
      AND provider_transport_request_digest IS NULL
      AND provider_transport_response_digest IS NULL
      AND provider_fetch_digest IS NULL
      AND fixture_authority IS NULL
      AND test_payment_outcome_config_digest IS NULL
      AND completion_request_digest IS NULL
      AND terminal_authority IS NULL
      AND local_failure_code IS NULL
      AND local_failure_evidence_digest IS NULL
      AND reconciliation_reason IN (
        'CHARGE_OUTCOME_UNKNOWN','FETCH_UNAVAILABLE','PROVIDER_PENDING',
        'PARTIAL_REFUND_AMOUNT_UNAVAILABLE'
      )
      AND reconciliation_evidence_digest IS NOT NULL
      AND provider_observed_at IS NULL AND terminal_at IS NULL
      OR attempt_state='RECONCILIATION_REQUIRED'
      AND reconciliation_reason='PARTIAL_REFUND_AMOUNT_UNAVAILABLE'
      AND provider_payment_id_digest=expected_provider_payment_id_digest
      AND provider_observed_state='PARTIALLY_REFUNDED'
      AND provider_transport_request_digest IS NOT NULL
      AND provider_transport_response_digest IS NOT NULL
      AND provider_fetch_digest IS NOT NULL
      AND fixture_authority='TEST_FIXTURE'
      AND test_payment_outcome_config_digest IS NOT NULL
      AND completion_request_digest IS NOT NULL
      AND terminal_authority IS NULL
      AND local_failure_code IS NULL
      AND local_failure_evidence_digest IS NULL
      AND reconciliation_evidence_digest=provider_fetch_digest
      AND provider_observed_at IS NOT NULL AND terminal_at IS NULL
      OR attempt_state='FAILED'
      AND terminal_authority='LOCAL_PRE_DISPATCH_REJECTION'
      AND producer_operation_id='private.ExecuteDonationCharge'
      AND provider_payment_id_digest IS NULL
      AND provider_observed_state IS NULL
      AND provider_transport_request_digest IS NULL
      AND provider_transport_response_digest IS NULL
      AND provider_fetch_digest IS NULL
      AND fixture_authority IS NULL
      AND test_payment_outcome_config_digest IS NULL
      AND completion_request_digest IS NOT NULL
      AND length(btrim(local_failure_code)) BETWEEN 1 AND 100
      AND local_failure_evidence_digest IS NOT NULL
      AND reconciliation_reason IS NULL
      AND reconciliation_evidence_digest IS NULL
      AND provider_observed_at IS NULL
      AND terminal_at IS NOT NULL AND terminal_at>=requested_at
      OR attempt_state IN ('SUCCEEDED','FAILED','REFUNDED')
      AND terminal_authority='PROVIDER_FETCH_CONFIRMED'
      AND provider_payment_id_digest IS NOT NULL
      AND provider_payment_id_digest=expected_provider_payment_id_digest
      AND provider_observed_state IN (
        'SUCCEEDED','FAILED','CANCELED','REFUNDED'
      )
      AND (
        attempt_state=provider_observed_state
        OR attempt_state='FAILED' AND provider_observed_state='CANCELED'
      )
      AND provider_transport_request_digest IS NOT NULL
      AND provider_transport_response_digest IS NOT NULL
      AND provider_fetch_digest IS NOT NULL
      AND fixture_authority='TEST_FIXTURE'
      AND test_payment_outcome_config_digest IS NOT NULL
      AND completion_request_digest IS NOT NULL
      AND local_failure_code IS NULL
      AND local_failure_evidence_digest IS NULL
      AND reconciliation_reason IS NULL
      AND reconciliation_evidence_digest IS NULL
      AND provider_observed_at IS NOT NULL
      AND provider_observed_at>=requested_at
      AND terminal_at IS NOT NULL AND terminal_at>=provider_observed_at
    )
  ),
  CONSTRAINT payment_charge_attempt_digest_ck CHECK (
    (predecessor_record_digest IS NULL
      OR predecessor_record_digest ~ '^[0-9a-f]{64}$')
    AND payment_method_binding_digest ~ '^[0-9a-f]{64}$'
    AND job_lease_token_digest ~ '^[0-9a-f]{64}$'
    AND job_binding_digest ~ '^[0-9a-f]{64}$'
    AND charge_idempotency_key_sha256 ~ '^[0-9a-f]{64}$'
    AND provider_idempotency_key_hmac ~ '^[0-9a-f]{64}$'
    AND merchant_order_id_hmac ~ '^[0-9a-f]{64}$'
    AND merchant_order_id_digest ~ '^[0-9a-f]{64}$'
    AND expected_provider_payment_id_digest ~ '^[0-9a-f]{64}$'
    AND (provider_payment_id_digest IS NULL
      OR provider_payment_id_digest ~ '^[0-9a-f]{64}$')
    AND request_digest ~ '^[0-9a-f]{64}$'
    AND (provider_transport_request_digest IS NULL
      OR provider_transport_request_digest ~ '^[0-9a-f]{64}$')
    AND (provider_transport_response_digest IS NULL
      OR provider_transport_response_digest ~ '^[0-9a-f]{64}$')
    AND (provider_fetch_digest IS NULL
      OR provider_fetch_digest ~ '^[0-9a-f]{64}$')
    AND (test_payment_outcome_config_digest IS NULL
      OR test_payment_outcome_config_digest ~ '^[0-9a-f]{64}$')
    AND (completion_request_digest IS NULL
      OR completion_request_digest ~ '^[0-9a-f]{64}$')
    AND (local_failure_evidence_digest IS NULL
      OR local_failure_evidence_digest ~ '^[0-9a-f]{64}$')
    AND (reconciliation_evidence_digest IS NULL
      OR reconciliation_evidence_digest ~ '^[0-9a-f]{64}$')
    AND record_digest ~ '^[0-9a-f]{64}$'
  )
);
ALTER TABLE ops.payment_charge_attempts OWNER TO gurine_migrator;
CREATE UNIQUE INDEX payment_charge_attempt_one_successor_uq
  ON ops.payment_charge_attempts(supersedes_attempt_id)
  WHERE supersedes_attempt_id IS NOT NULL;
CREATE UNIQUE INDEX payment_charge_attempt_job_root_uq
  ON ops.payment_charge_attempts(job_id) WHERE observation_version=1;
CREATE UNIQUE INDEX payment_charge_attempt_logical_root_uq
  ON ops.payment_charge_attempts(logical_charge_id) WHERE observation_version=1;
CREATE UNIQUE INDEX payment_charge_attempt_provider_idempotency_uq
  ON ops.payment_charge_attempts(provider,provider_idempotency_key_hmac)
  WHERE observation_version=1;
CREATE UNIQUE INDEX payment_charge_attempt_merchant_order_uq
  ON ops.payment_charge_attempts(provider,merchant_order_id_hmac)
  WHERE observation_version=1;
CREATE UNIQUE INDEX payment_charge_attempt_expected_provider_locator_uq
  ON ops.payment_charge_attempts(provider,expected_provider_payment_id_digest)
  WHERE observation_version=1;
ALTER TABLE ops.payment_charge_attempts ADD CONSTRAINT payment_charge_attempt_root_fk
  FOREIGN KEY (root_attempt_id) REFERENCES ops.payment_charge_attempts(id)
  ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.payment_charge_attempts ADD CONSTRAINT payment_charge_attempt_supersedes_fk
  FOREIGN KEY (supersedes_attempt_id,predecessor_record_digest)
  REFERENCES ops.payment_charge_attempts(id,record_digest)
  MATCH FULL ON DELETE RESTRICT;
ALTER TABLE ops.payment_charge_attempts ADD CONSTRAINT payment_charge_attempt_binding_fk
  FOREIGN KEY (payment_method_binding_id,payment_method_binding_digest)
  REFERENCES ops.payment_method_bindings(id,record_digest) ON DELETE RESTRICT;
ALTER TABLE ops.payment_charge_attempts ADD CONSTRAINT payment_charge_attempt_job_fk
  FOREIGN KEY (job_id) REFERENCES ops.jobs(id) ON DELETE RESTRICT;

CREATE TABLE ops.provider_webhook_receipts (
  id uuid PRIMARY KEY,
  root_receipt_id uuid NOT NULL,
  revision bigint NOT NULL,
  receipt_effect text NOT NULL,
  supersedes_receipt_id uuid,
  predecessor_receipt_digest char(64),
  environment text NOT NULL,
  fixture_authority text NOT NULL,
  provider text NOT NULL,
  provider_event_identity_digest char(64) NOT NULL,
  locator_kind text NOT NULL,
  locator_digest char(64) NOT NULL,
  body_digest char(64) NOT NULL,
  hint_digest char(64) NOT NULL,
  authentication_state text NOT NULL,
  signature_digest char(64),
  signed_payload_digest char(64),
  claim_state text NOT NULL,
  claim_request_digest char(64) NOT NULL,
  charge_attempt_id uuid NOT NULL,
  charge_attempt_digest char(64) NOT NULL,
  logical_charge_id uuid NOT NULL,
  job_binding_digest char(64) NOT NULL,
  charge_idempotency_key_sha256 char(64) NOT NULL,
  merchant_order_id_digest char(64) NOT NULL,
  amount numeric(24,6) NOT NULL,
  currency char(3) NOT NULL,
  release_code text,
  release_evidence_digest char(64),
  provider_payment_state text,
  provider_payment_id_digest char(64),
  provider_fetch_request_digest char(64),
  provider_fetch_response_digest char(64),
  provider_fetch_digest char(64),
  payment_fixture_authority text,
  test_payment_outcome_config_digest char(64),
  completion_request_digest char(64),
  provider_observed_at timestamptz,
  resulting_charge_attempt_id uuid,
  resulting_charge_attempt_digest char(64),
  resulting_donation_fact_id uuid,
  resulting_donation_fact_digest char(64),
  claimed_at timestamptz NOT NULL,
  released_at timestamptz,
  fetched_at timestamptz,
  audit_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT provider_webhook_root_revision_uq
    UNIQUE (root_receipt_id,revision),
  CONSTRAINT provider_webhook_receipt_digest_uq UNIQUE (receipt_digest),
  CONSTRAINT provider_webhook_row_reference_uq UNIQUE (id,receipt_digest),
  CONSTRAINT provider_webhook_reference_uq
    UNIQUE (root_receipt_id,receipt_digest),
  CONSTRAINT provider_webhook_chain_ck CHECK (
    revision>0 AND (
      receipt_effect='ORIGINAL' AND revision=1 AND root_receipt_id=id
      AND supersedes_receipt_id IS NULL AND predecessor_receipt_digest IS NULL
      AND claim_state='CLAIMED'
      OR receipt_effect='RELEASE' AND revision>1 AND root_receipt_id<>id
      AND supersedes_receipt_id IS NOT NULL
      AND predecessor_receipt_digest IS NOT NULL
      AND claim_state='RELEASED'
      OR receipt_effect='RECLAIM' AND revision>1 AND root_receipt_id<>id
      AND supersedes_receipt_id IS NOT NULL
      AND predecessor_receipt_digest IS NOT NULL
      AND claim_state='CLAIMED'
      OR receipt_effect='FETCH' AND revision>1 AND root_receipt_id<>id
      AND supersedes_receipt_id IS NOT NULL
      AND predecessor_receipt_digest IS NOT NULL
      AND claim_state='FETCH_CONFIRMED'
    )
  ),
  CONSTRAINT provider_webhook_shape_ck CHECK (
    provider IN ('TOSS_PAYMENTS','KAKAO_PAY','STRIPE')
    AND environment='TEST'
    AND fixture_authority='TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY'
    AND locator_kind IN ('PROVIDER_PAYMENT_ID','MERCHANT_ORDER_ID')
    AND authentication_state IN ('VERIFIED','NOT_AVAILABLE_FETCH_REQUIRED')
    AND (
      provider='STRIPE' AND authentication_state='VERIFIED'
      OR provider IN ('TOSS_PAYMENTS','KAKAO_PAY')
      AND authentication_state='NOT_AVAILABLE_FETCH_REQUIRED'
    )
    AND amount>0 AND trunc(amount)=amount AND currency='KRW'
    AND (
      authentication_state='VERIFIED'
      AND signature_digest IS NOT NULL AND signed_payload_digest IS NOT NULL
      OR authentication_state='NOT_AVAILABLE_FETCH_REQUIRED'
      AND signature_digest IS NULL AND signed_payload_digest IS NULL
    )
    AND (
      claim_state='CLAIMED'
      AND release_code IS NULL AND release_evidence_digest IS NULL
      AND provider_payment_state IS NULL
      AND provider_payment_id_digest IS NULL
      AND provider_fetch_request_digest IS NULL
      AND provider_fetch_response_digest IS NULL
      AND provider_fetch_digest IS NULL AND provider_observed_at IS NULL
      AND payment_fixture_authority IS NULL
      AND test_payment_outcome_config_digest IS NULL
      AND completion_request_digest IS NULL
      AND resulting_charge_attempt_id IS NULL
      AND resulting_charge_attempt_digest IS NULL
      AND resulting_donation_fact_id IS NULL
      AND resulting_donation_fact_digest IS NULL
      AND released_at IS NULL AND fetched_at IS NULL
      OR claim_state='RELEASED'
      AND length(btrim(release_code)) BETWEEN 1 AND 100
      AND release_evidence_digest IS NOT NULL
      AND provider_payment_state IS NULL
      AND provider_payment_id_digest IS NULL
      AND provider_fetch_request_digest IS NULL
      AND provider_fetch_response_digest IS NULL
      AND provider_fetch_digest IS NULL AND provider_observed_at IS NULL
      AND payment_fixture_authority IS NULL
      AND test_payment_outcome_config_digest IS NULL
      AND completion_request_digest IS NULL
      AND resulting_charge_attempt_id IS NULL
      AND resulting_charge_attempt_digest IS NULL
      AND resulting_donation_fact_id IS NULL
      AND resulting_donation_fact_digest IS NULL
      AND released_at IS NOT NULL AND released_at>=claimed_at
      AND fetched_at IS NULL
      OR claim_state='FETCH_CONFIRMED'
      AND release_code IS NULL AND release_evidence_digest IS NULL
      AND provider_payment_state IN (
        'PENDING','SUCCEEDED','FAILED','CANCELED','PARTIALLY_REFUNDED','REFUNDED'
      )
      AND provider_payment_id_digest IS NOT NULL
      AND provider_fetch_request_digest IS NOT NULL
      AND provider_fetch_response_digest IS NOT NULL
      AND provider_fetch_digest IS NOT NULL
      AND payment_fixture_authority='TEST_FIXTURE'
      AND test_payment_outcome_config_digest IS NOT NULL
      AND completion_request_digest IS NOT NULL
      AND provider_observed_at IS NOT NULL
      AND resulting_charge_attempt_id IS NOT NULL
      AND resulting_charge_attempt_digest IS NOT NULL
      AND (resulting_donation_fact_id IS NULL)
        = (resulting_donation_fact_digest IS NULL)
      AND released_at IS NULL AND fetched_at IS NOT NULL
      AND fetched_at>=provider_observed_at
    )
  ),
  CONSTRAINT provider_webhook_digest_ck CHECK (
    (predecessor_receipt_digest IS NULL
      OR predecessor_receipt_digest ~ '^[0-9a-f]{64}$')
    AND provider_event_identity_digest ~ '^[0-9a-f]{64}$'
    AND locator_digest ~ '^[0-9a-f]{64}$'
    AND body_digest ~ '^[0-9a-f]{64}$'
    AND hint_digest ~ '^[0-9a-f]{64}$'
    AND (signature_digest IS NULL OR signature_digest ~ '^[0-9a-f]{64}$')
    AND (signed_payload_digest IS NULL
      OR signed_payload_digest ~ '^[0-9a-f]{64}$')
    AND claim_request_digest ~ '^[0-9a-f]{64}$'
    AND charge_attempt_digest ~ '^[0-9a-f]{64}$'
    AND job_binding_digest ~ '^[0-9a-f]{64}$'
    AND charge_idempotency_key_sha256 ~ '^[0-9a-f]{64}$'
    AND merchant_order_id_digest ~ '^[0-9a-f]{64}$'
    AND (release_evidence_digest IS NULL
      OR release_evidence_digest ~ '^[0-9a-f]{64}$')
    AND (provider_payment_id_digest IS NULL
      OR provider_payment_id_digest ~ '^[0-9a-f]{64}$')
    AND (provider_fetch_request_digest IS NULL
      OR provider_fetch_request_digest ~ '^[0-9a-f]{64}$')
    AND (provider_fetch_response_digest IS NULL
      OR provider_fetch_response_digest ~ '^[0-9a-f]{64}$')
    AND (provider_fetch_digest IS NULL
      OR provider_fetch_digest ~ '^[0-9a-f]{64}$')
    AND (test_payment_outcome_config_digest IS NULL
      OR test_payment_outcome_config_digest ~ '^[0-9a-f]{64}$')
    AND (completion_request_digest IS NULL
      OR completion_request_digest ~ '^[0-9a-f]{64}$')
    AND (resulting_charge_attempt_digest IS NULL
      OR resulting_charge_attempt_digest ~ '^[0-9a-f]{64}$')
    AND (resulting_donation_fact_digest IS NULL
      OR resulting_donation_fact_digest ~ '^[0-9a-f]{64}$')
    AND receipt_digest ~ '^[0-9a-f]{64}$'
  )
);
ALTER TABLE ops.provider_webhook_receipts OWNER TO gurine_migrator;
CREATE UNIQUE INDEX provider_webhook_one_successor_uq
  ON ops.provider_webhook_receipts(supersedes_receipt_id)
  WHERE supersedes_receipt_id IS NOT NULL;
CREATE UNIQUE INDEX provider_webhook_event_identity_uq
  ON ops.provider_webhook_receipts(provider,provider_event_identity_digest)
  WHERE revision=1;
ALTER TABLE ops.provider_webhook_receipts ADD CONSTRAINT provider_webhook_root_fk
  FOREIGN KEY (root_receipt_id) REFERENCES ops.provider_webhook_receipts(id)
  ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.provider_webhook_receipts ADD CONSTRAINT provider_webhook_supersedes_fk
  FOREIGN KEY (supersedes_receipt_id,predecessor_receipt_digest)
  REFERENCES ops.provider_webhook_receipts(id,receipt_digest)
  MATCH FULL ON DELETE RESTRICT;
ALTER TABLE ops.provider_webhook_receipts ADD CONSTRAINT provider_webhook_charge_source_fk
  FOREIGN KEY (charge_attempt_id,charge_attempt_digest)
  REFERENCES ops.payment_charge_attempts(root_attempt_id,record_digest)
  ON DELETE RESTRICT;

CREATE TABLE ops.donation_facts (
  id uuid PRIMARY KEY,
  root_fact_id uuid NOT NULL,
  revision bigint NOT NULL,
  fact_effect text NOT NULL,
  supersedes_fact_id uuid,
  predecessor_fact_digest char(64),
  deployment_id uuid NOT NULL,
  payment_charge_attempt_id uuid NOT NULL,
  payment_charge_attempt_digest char(64) NOT NULL,
  donor_hmac char(64) NOT NULL,
  donor_hmac_key_version text NOT NULL,
  donor_group_hmac char(64) NOT NULL,
  donor_group_hmac_key_version text NOT NULL,
  amount numeric(24,6) NOT NULL,
  currency char(3) NOT NULL,
  amount_basis ops.funding_amount_basis NOT NULL,
  funding_source_kind ops.funding_source_kind NOT NULL,
  investigation_exemption boolean NOT NULL DEFAULT false,
  access_entitlement_granted boolean NOT NULL DEFAULT false,
  provider_fetch_digest char(64) NOT NULL,
  recognized_at timestamptz NOT NULL,
  audit_event_id uuid NOT NULL,
  fact_digest char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT donation_fact_root_revision_uq UNIQUE (root_fact_id,revision),
  CONSTRAINT donation_fact_digest_uq UNIQUE (fact_digest),
  CONSTRAINT donation_fact_reference_uq UNIQUE (id,fact_digest),
  CONSTRAINT donation_fact_charge_revision_uq UNIQUE (
    payment_charge_attempt_id,revision
  ),
  CONSTRAINT donation_fact_chain_ck CHECK (
    revision>0 AND (
      fact_effect='ORIGINAL' AND revision=1 AND root_fact_id=id
      AND supersedes_fact_id IS NULL AND predecessor_fact_digest IS NULL
      OR fact_effect IN ('REPLACEMENT','REVERSAL') AND revision>1
      AND root_fact_id<>id AND supersedes_fact_id IS NOT NULL
      AND predecessor_fact_digest IS NOT NULL
    )
  ),
  CONSTRAINT donation_fact_public_firewall_ck CHECK (
    amount>0 AND currency ~ '^[A-Z]{3}$'
    AND funding_source_kind='DONATION'
    AND investigation_exemption=false
    AND access_entitlement_granted=false
  ),
  CONSTRAINT donation_fact_digest_ck CHECK (
    (predecessor_fact_digest IS NULL
      OR predecessor_fact_digest ~ '^[0-9a-f]{64}$')
    AND payment_charge_attempt_digest ~ '^[0-9a-f]{64}$'
    AND donor_hmac ~ '^[0-9a-f]{64}$'
    AND donor_group_hmac ~ '^[0-9a-f]{64}$'
    AND provider_fetch_digest ~ '^[0-9a-f]{64}$'
    AND fact_digest ~ '^[0-9a-f]{64}$'
  )
);
ALTER TABLE ops.donation_facts OWNER TO gurine_migrator;
CREATE UNIQUE INDEX donation_fact_one_successor_uq
  ON ops.donation_facts(supersedes_fact_id)
  WHERE supersedes_fact_id IS NOT NULL;
ALTER TABLE ops.donation_facts ADD CONSTRAINT donation_fact_root_fk
  FOREIGN KEY (root_fact_id) REFERENCES ops.donation_facts(id)
  ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.donation_facts ADD CONSTRAINT donation_fact_supersedes_fk
  FOREIGN KEY (supersedes_fact_id,predecessor_fact_digest)
  REFERENCES ops.donation_facts(id,fact_digest)
  MATCH FULL ON DELETE RESTRICT;
ALTER TABLE ops.donation_facts ADD CONSTRAINT donation_fact_charge_fk
  FOREIGN KEY (payment_charge_attempt_id,payment_charge_attempt_digest)
  REFERENCES ops.payment_charge_attempts(root_attempt_id,record_digest)
  ON DELETE RESTRICT;

ALTER TABLE ops.provider_webhook_receipts ADD CONSTRAINT provider_webhook_charge_fk
  FOREIGN KEY (resulting_charge_attempt_id,resulting_charge_attempt_digest)
  REFERENCES ops.payment_charge_attempts(root_attempt_id,record_digest)
  MATCH FULL ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.provider_webhook_receipts ADD CONSTRAINT provider_webhook_donation_fk
  FOREIGN KEY (resulting_donation_fact_id,resulting_donation_fact_digest)
  REFERENCES ops.donation_facts(id,fact_digest)
  MATCH FULL ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

-- R6E_ECONOMICS_OWNER_FUNCTIONS

-- Every signed economics relation has one direct-DML routine.  Runtime
-- principals never receive table DML or EXECUTE on these helpers: the
-- SECURITY DEFINER apply orchestrator is the only caller, and session_user
-- remains the dedicated importer throughout that call chain.
CREATE FUNCTION ops.economics_import_row_digest_v1(
  p_schema_version text,
  p_row jsonb,
  p_excluded_fields text[]
) RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion',p_schema_version,
      'row',p_row-COALESCE(p_excluded_fields,'{}'::text[])
    )),'sha256'
  ),'hex')::char(64)
$$;
ALTER FUNCTION ops.economics_import_row_digest_v1(text,jsonb,text[])
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.economics_import_row_digest_v1(text,jsonb,text[]) FROM PUBLIC;

CREATE FUNCTION ops.insert_fx_rate_fact_v1(
  p_row ops.fx_rate_facts
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
SET timezone='UTC'
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_FX_RATE_ROW_INVALID' USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.fx_rate_facts SELECT (p_row).*;
  RETURN ('FX_RATE_FACT',(p_row).id,(p_row).revision,(p_row).sha256)
    ::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_fx_rate_fact_v1(ops.fx_rate_facts)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_fx_rate_fact_v1(ops.fx_rate_facts)
  FROM PUBLIC;

CREATE FUNCTION ops.insert_acquisition_source_receipt_v1(
  p_row ops.acquisition_source_receipts
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_ACQUISITION_ROW_INVALID'
      USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.acquisition_source_receipts SELECT (p_row).*;
  RETURN (
    'ACQUISITION_SOURCE_RECEIPT',(p_row).id,(p_row).revision,
    (p_row).receipt_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_acquisition_source_receipt_v1(
  ops.acquisition_source_receipts
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_acquisition_source_receipt_v1(
  ops.acquisition_source_receipts
) FROM PUBLIC;

CREATE FUNCTION ops.insert_cost_allocation_v1(
  p_row ops.cost_allocations
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL OR (p_row).row_kind NOT IN ('PERIOD','LINE') THEN
    RAISE EXCEPTION 'ECONOMICS_COST_ALLOCATION_ROW_INVALID'
      USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.cost_allocations SELECT (p_row).*;
  RETURN (
    CASE (p_row).row_kind WHEN 'PERIOD' THEN 'COST_ALLOCATION_PERIOD'
      ELSE 'COST_ALLOCATION_LINE' END,
    (p_row).id,(p_row).period_version,(p_row).record_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_cost_allocation_v1(ops.cost_allocations)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_cost_allocation_v1(ops.cost_allocations)
  FROM PUBLIC;

CREATE FUNCTION ops.insert_tariff_version_v1(
  p_row ops.tariff_versions
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_TARIFF_ROW_INVALID' USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.tariff_versions SELECT (p_row).*;
  RETURN ('TARIFF_VERSION',(p_row).id,NULL,(p_row).record_digest)
    ::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_tariff_version_v1(ops.tariff_versions)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_tariff_version_v1(ops.tariff_versions)
  FROM PUBLIC;

CREATE FUNCTION ops.insert_commercial_contract_period_v1(
  p_row ops.commercial_contract_periods
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_CONTRACT_ROW_INVALID' USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.commercial_contract_periods SELECT (p_row).*;
  RETURN (
    'COMMERCIAL_CONTRACT_PERIOD',(p_row).id,(p_row).revision,
    (p_row).record_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_commercial_contract_period_v1(
  ops.commercial_contract_periods
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_commercial_contract_period_v1(
  ops.commercial_contract_periods
) FROM PUBLIC;

CREATE FUNCTION ops.insert_usage_window_receipt_v1(
  p_row ops.usage_window_receipts
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_USAGE_RECEIPT_ROW_INVALID'
      USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.usage_window_receipts SELECT (p_row).*;
  RETURN (
    'USAGE_WINDOW_RECEIPT',(p_row).id,(p_row).receipt_version,
    (p_row).receipt_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_usage_window_receipt_v1(
  ops.usage_window_receipts
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_usage_window_receipt_v1(
  ops.usage_window_receipts
) FROM PUBLIC;

CREATE FUNCTION ops.insert_discount_decision_v1(
  p_row ops.discount_decisions
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_DISCOUNT_ROW_INVALID' USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.discount_decisions SELECT (p_row).*;
  RETURN (
    'DISCOUNT_DECISION',(p_row).id,(p_row).revision,(p_row).record_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_discount_decision_v1(ops.discount_decisions)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_discount_decision_v1(ops.discount_decisions)
  FROM PUBLIC;

CREATE FUNCTION ops.insert_offer_profile_capability_v1(
  p_row ops.offer_profile_capabilities
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_OFFER_CAPABILITY_ROW_INVALID'
      USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.offer_profile_capabilities SELECT (p_row).*;
  RETURN (
    'OFFER_PROFILE_CAPABILITY',(p_row).offer_profile_id,
    (p_row).offer_profile_version,(p_row).entry_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_offer_profile_capability_v1(
  ops.offer_profile_capabilities
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_offer_profile_capability_v1(
  ops.offer_profile_capabilities
) FROM PUBLIC;

CREATE FUNCTION ops.insert_cash_application_fact_v1(
  p_row ops.cash_application_facts
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_CASH_APPLICATION_ROW_INVALID'
      USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.cash_application_facts SELECT (p_row).*;
  RETURN (
    'CASH_APPLICATION_FACT',(p_row).id,(p_row).revision,(p_row).fact_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_cash_application_fact_v1(
  ops.cash_application_facts
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_cash_application_fact_v1(
  ops.cash_application_facts
) FROM PUBLIC;

CREATE FUNCTION ops.insert_tax_invoice_issuance_receipt_v1(
  p_row ops.tax_invoice_issuance_receipts
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_TAX_INVOICE_ROW_INVALID'
      USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.tax_invoice_issuance_receipts SELECT (p_row).*;
  RETURN (
    'TAX_INVOICE_ISSUANCE_RECEIPT',(p_row).id,(p_row).revision,
    (p_row).receipt_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_tax_invoice_issuance_receipt_v1(
  ops.tax_invoice_issuance_receipts
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_tax_invoice_issuance_receipt_v1(
  ops.tax_invoice_issuance_receipts
) FROM PUBLIC;

CREATE FUNCTION ops.insert_usage_fact_v1(
  p_row ops.usage_facts
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' OR p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  INSERT INTO ops.usage_facts SELECT (p_row).*;
  RETURN ('USAGE_FACT',(p_row).id,(p_row).revision,(p_row).record_digest)
    ::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_usage_fact_v1(ops.usage_facts)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_usage_fact_v1(ops.usage_facts) FROM PUBLIC;

CREATE FUNCTION ops.insert_invoice_fact_v1(
  p_row ops.invoice_facts
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' OR p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  INSERT INTO ops.invoice_facts SELECT (p_row).*;
  RETURN (
    'INVOICE_FACT',(p_row).id,(p_row).invoice_revision,(p_row).record_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_invoice_fact_v1(ops.invoice_facts)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_invoice_fact_v1(ops.invoice_facts)
  FROM PUBLIC;

CREATE FUNCTION ops.insert_invoice_line_fact_v1(
  p_row ops.invoice_line_facts
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' OR p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  INSERT INTO ops.invoice_line_facts SELECT (p_row).*;
  RETURN ('INVOICE_LINE_FACT',(p_row).id,1,(p_row).line_digest)
    ::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_invoice_line_fact_v1(ops.invoice_line_facts)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_invoice_line_fact_v1(
  ops.invoice_line_facts
) FROM PUBLIC;

CREATE FUNCTION ops.insert_invoice_usage_membership_v1(
  p_row ops.invoice_usage_memberships
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' OR p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  INSERT INTO ops.invoice_usage_memberships SELECT (p_row).*;
  RETURN (
    'INVOICE_USAGE_MEMBERSHIP',(p_row).id,(p_row).revision,
    (p_row).membership_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_invoice_usage_membership_v1(
  ops.invoice_usage_memberships
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_invoice_usage_membership_v1(
  ops.invoice_usage_memberships
) FROM PUBLIC;

CREATE FUNCTION ops.insert_revenue_fact_v1(
  p_row ops.revenue_facts
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' OR p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  INSERT INTO ops.revenue_facts SELECT (p_row).*;
  RETURN ('REVENUE_FACT',(p_row).id,NULL,(p_row).record_digest)
    ::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_revenue_fact_v1(ops.revenue_facts)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_revenue_fact_v1(ops.revenue_facts)
  FROM PUBLIC;

CREATE FUNCTION ops.insert_accounting_correction_v1(
  p_row ops.accounting_corrections
) RETURNS ops.economics_import_result_row_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' OR p_row IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_DIRECT_MUTATOR_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  INSERT INTO ops.accounting_corrections SELECT (p_row).*;
  RETURN (
    'ACCOUNTING_CORRECTION',(p_row).id,(p_row).revision,
    (p_row).record_digest
  )::ops.economics_import_result_row_v1;
END
$$;
ALTER FUNCTION ops.insert_accounting_correction_v1(
  ops.accounting_corrections
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.insert_accounting_correction_v1(
  ops.accounting_corrections
) FROM PUBLIC;

-- These seven closed 0029/0030 routines remain the sole direct mutator for
-- their relation.  They become private implementation details of the migrator;
-- their former workflow-worker side door is revoked again at migration end.
ALTER FUNCTION ops.record_commercial_qualification_receipt_v1(
  ops.commercial_qualification_receipt_input_v1,text
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_revenue_fact_v1(jsonb,uuid,char(64))
  OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_invoice_fact_v1(jsonb)
  OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_invoice_line_fact_v1(jsonb)
  OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_usage_fact_v1(jsonb)
  OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_invoice_usage_membership_v1(jsonb)
  OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_accounting_correction_v1(jsonb)
  OWNER TO gurine_migrator;

REVOKE ALL ON FUNCTION
  ops.record_commercial_qualification_receipt_v1(
    ops.commercial_qualification_receipt_input_v1,text
  ),
  ops.record_revenue_fact_v1(jsonb,uuid,char(64)),
  ops.record_invoice_fact_v1(jsonb),
  ops.record_invoice_line_fact_v1(jsonb),
  ops.record_usage_fact_v1(jsonb),
  ops.record_invoice_usage_membership_v1(jsonb),
  ops.record_accounting_correction_v1(jsonb)
FROM PUBLIC,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_public_projector,gurine_public_api,
  gurine_submission_api,gurine_ingest_worker,gurine_notification_worker,
  gurine_scheduler,gurine_document_extractor,gurine_identity_api,
  gurine_auditor,gurine_billing_gateway,gurine_economics_importer;

-- R6E_ECONOMICS_AUX_OWNER_FUNCTIONS

-- The public economics draft is closed JSON, while the persisted operation is
-- a tree of PostgreSQL composites.  Compile that tree without dynamic SQL and
-- reject every unknown or omitted field before jsonb_populate_record can turn
-- an omission into an indistinguishable NULL.
CREATE TYPE ops.economics_import_compiled_draft_v1 AS (
  operation_id text,
  operation_value ops.economics_import_operation_v1,
  operation_canonical bytea,
  operation_digest char(64),
  source_evidence_segment_ids uuid[],
  source_evidence_digests char(64)[],
  source_evidence_set_digest char(64),
  import_policy_digest char(64),
  as_of timestamptz,
  content_digest char(64),
  detail_binding_canonical bytea,
  action_detail_digest char(64),
  proposer_capability_set_digest char(64),
  reviewer_capability_set_digest char(64),
  requires_oversight boolean
);
REVOKE ALL ON TYPE ops.economics_import_compiled_draft_v1 FROM PUBLIC;

CREATE FUNCTION ops.economics_camel_to_snake_v1(
  p_key text
) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
  SELECT lower(regexp_replace(p_key,'([A-Z])',E'_\\1','g'))
$$;
ALTER FUNCTION ops.economics_camel_to_snake_v1(text)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_camel_to_snake_v1(text) FROM PUBLIC;

CREATE FUNCTION ops.economics_decimal_wire_v1(
  p_value jsonb,
  p_precision integer,
  p_scale integer
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
DECLARE
  v_text text;
  v_unsigned text;
  v_integer text;
  v_fraction text;
BEGIN
  IF p_value='null'::jsonb THEN
    RETURN true;
  END IF;
  IF jsonb_typeof(p_value)<>'string'
     OR p_precision<1 OR p_scale<0 OR p_scale>=p_precision THEN
    RETURN false;
  END IF;
  v_text:=p_value#>>'{}';
  IF v_text IS NULL OR v_text!~'^-?(0|[1-9][0-9]*)(\.[0-9]*[1-9])?$'
     OR v_text='-0' THEN
    RETURN false;
  END IF;
  v_unsigned:=CASE WHEN left(v_text,1)='-' THEN substr(v_text,2)
    ELSE v_text END;
  v_integer:=split_part(v_unsigned,'.',1);
  v_fraction:=CASE WHEN strpos(v_unsigned,'.')=0 THEN ''
    ELSE split_part(v_unsigned,'.',2) END;
  RETURN length(v_integer)<=p_precision-p_scale
    AND length(v_fraction)<=p_scale;
END
$$;
ALTER FUNCTION ops.economics_decimal_wire_v1(jsonb,integer,integer)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_decimal_wire_v1(
  jsonb,integer,integer
) FROM PUBLIC;

CREATE FUNCTION ops.economics_compile_composite_json_v1(
  p_value jsonb,
  p_type regtype
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_relation oid;
  v_type_name text;
  v_entry record;
  v_attribute record;
  v_snake text;
  v_compiled jsonb:='{}'::jsonb;
  v_value jsonb;
  v_element_type oid;
  v_element_kind char;
  v_precision integer;
  v_scale integer;
  v_attribute_count bigint;
  v_compiled_count bigint;
  v_derived jsonb:='{}'::jsonb;
BEGIN
  IF p_value='null'::jsonb THEN
    RETURN p_value;
  END IF;
  IF p_value IS NULL OR jsonb_typeof(p_value)<>'object' THEN
    RAISE EXCEPTION 'ECONOMICS_COMPOSITE_WIRE_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT type.typrelid,type.typname
    INTO v_relation,v_type_name
  FROM pg_type AS type
  JOIN pg_namespace AS namespace ON namespace.oid=type.typnamespace
  WHERE type.oid=p_type::oid AND namespace.nspname='ops'
    AND type.typtype='c';
  IF v_relation IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_COMPOSITE_TYPE_INVALID'
      USING ERRCODE='22023';
  END IF;

  FOR v_entry IN SELECT key,value FROM jsonb_each(p_value)
  LOOP
    v_snake:=ops.economics_camel_to_snake_v1(v_entry.key);
    IF v_compiled ? v_snake THEN
      RAISE EXCEPTION 'ECONOMICS_COMPOSITE_KEY_COLLISION'
        USING ERRCODE='22023';
    END IF;
    SELECT attribute.atttypid,attribute.atttypmod,
           type.typtype,type.typelem
      INTO v_attribute
    FROM pg_attribute AS attribute
    JOIN pg_type AS type ON type.oid=attribute.atttypid
    WHERE attribute.attrelid=v_relation
      AND attribute.attnum>0 AND NOT attribute.attisdropped
      AND attribute.attname=v_snake;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'ECONOMICS_COMPOSITE_UNKNOWN_FIELD'
        USING ERRCODE='22023';
    END IF;
    v_value:=v_entry.value;
    IF v_value<>'null'::jsonb AND v_attribute.atttypid='numeric'::regtype THEN
      IF v_attribute.atttypmod<4 THEN
        RAISE EXCEPTION 'ECONOMICS_DECIMAL_TYPE_UNBOUNDED'
          USING ERRCODE='22023';
      END IF;
      v_precision:=((v_attribute.atttypmod-4)>>16)&65535;
      v_scale:=(v_attribute.atttypmod-4)&65535;
      IF NOT ops.economics_decimal_wire_v1(
        v_value,v_precision,v_scale
      ) THEN
        RAISE EXCEPTION 'ECONOMICS_DECIMAL_WIRE_INVALID'
          USING ERRCODE='22023';
      END IF;
    ELSIF v_value<>'null'::jsonb AND v_attribute.typtype='c' THEN
      v_value:=ops.economics_compile_composite_json_v1(
        v_value,v_attribute.atttypid::regtype
      );
    ELSIF v_value<>'null'::jsonb AND v_attribute.typelem<>0 THEN
      IF jsonb_typeof(v_value)<>'array' THEN
        RAISE EXCEPTION 'ECONOMICS_COMPOSITE_ARRAY_INVALID'
          USING ERRCODE='22023';
      END IF;
      v_element_type:=v_attribute.typelem;
      SELECT type.typtype INTO v_element_kind
      FROM pg_type AS type WHERE type.oid=v_element_type;
      IF v_element_kind='c' THEN
        SELECT COALESCE(jsonb_agg(
          ops.economics_compile_composite_json_v1(
            element.value,v_element_type::regtype
          ) ORDER BY element.ordinality
        ),'[]'::jsonb) INTO v_value
        FROM jsonb_array_elements(v_value) WITH ORDINALITY
          AS element(value,ordinality);
      END IF;
    END IF;
    v_compiled:=v_compiled||jsonb_build_object(v_snake,v_value);
  END LOOP;

  v_derived:=CASE v_type_name
    WHEN 'economics_fx_rate_append_v1' THEN jsonb_build_object(
      'approver_id',NULL,'decision_digest',NULL
    )
    WHEN 'economics_discount_append_v1' THEN jsonb_build_object(
      'oversight_expires_at',NULL,'oversight_approver_id',NULL,
      'oversight_decision_digest',NULL,'proposed_by',NULL,
      'approver_id',NULL,'decision_digest',NULL
    )
    WHEN 'economics_tariff_import_v1' THEN jsonb_build_object(
      'margin_exception_expires_at',NULL,'oversight_approver_id',NULL,
      'oversight_decision_digest',NULL,'proposed_by',NULL,
      'approver_id',NULL,'decision_digest',NULL
    )
    WHEN 'economics_contract_import_v1' THEN jsonb_build_object(
      'approver_id',NULL,'decision_digest',NULL
    )
    WHEN 'economics_accounting_correction_import_v1' THEN
      jsonb_build_object(
        'proposed_by',NULL,'approver_id',NULL,'decision_digest',NULL
      )
    ELSE '{}'::jsonb
  END;
  IF EXISTS (
    SELECT 1 FROM jsonb_object_keys(v_derived) AS derived(key)
    WHERE v_compiled ? derived.key
  ) THEN
    RAISE EXCEPTION 'ECONOMICS_DERIVED_GOVERNANCE_FORBIDDEN'
      USING ERRCODE='22023';
  END IF;
  v_compiled:=v_compiled||v_derived;
  SELECT count(*) INTO v_attribute_count
  FROM pg_attribute AS attribute
  WHERE attribute.attrelid=v_relation
    AND attribute.attnum>0 AND NOT attribute.attisdropped;
  SELECT count(*) INTO v_compiled_count FROM jsonb_object_keys(v_compiled);
  IF v_compiled_count<>v_attribute_count THEN
    RAISE EXCEPTION 'ECONOMICS_COMPOSITE_REQUIRED_FIELD_MISSING'
      USING ERRCODE='22023';
  END IF;
  RETURN v_compiled;
END
$$;
ALTER FUNCTION ops.economics_compile_composite_json_v1(jsonb,regtype)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_compile_composite_json_v1(
  jsonb,regtype
) FROM PUBLIC;

CREATE FUNCTION ops.compile_economics_import_operation_v1(
  p_operation jsonb
) RETURNS ops.economics_import_operation_v1
LANGUAGE plpgsql STABLE
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_operation_id text;
  v_branch_name text;
  v_branch_type regtype;
  v_branch jsonb;
  v_outer jsonb;
  v_result ops.economics_import_operation_v1;
BEGIN
  IF p_operation IS NULL OR jsonb_typeof(p_operation)<>'object'
     OR jsonb_typeof(p_operation->'operationId')<>'string' THEN
    RAISE EXCEPTION 'ECONOMICS_OPERATION_WIRE_INVALID'
      USING ERRCODE='22023';
  END IF;
  v_operation_id:=p_operation->>'operationId';
  SELECT branch_name,branch_type INTO v_branch_name,v_branch_type
  FROM (VALUES
    ('recordCommercialQualification','record_commercial_qualification',
      'ops.economics_qualification_import_v1'::regtype),
    ('importCostAllocationClose','import_cost_allocation_close',
      'ops.economics_cost_close_import_v1'::regtype),
    ('createTariffVersion','create_tariff_version',
      'ops.economics_tariff_import_v1'::regtype),
    ('recordCommercialContractPeriod','record_commercial_contract_period',
      'ops.economics_contract_import_v1'::regtype),
    ('recordUsageWindow','record_usage_window',
      'ops.economics_usage_window_import_v1'::regtype),
    ('recordInvoice','record_invoice',
      'ops.economics_invoice_import_v1'::regtype),
    ('recordRevenue','record_revenue',
      'ops.economics_revenue_import_v1'::regtype),
    ('recordAccountingCorrection','record_accounting_correction',
      'ops.economics_accounting_corrections_import_v1'::regtype),
    ('recordCashApplication','record_cash_application',
      'ops.economics_cash_applications_import_v1'::regtype),
    ('recordTaxInvoiceIssuance','record_tax_invoice_issuance',
      'ops.economics_tax_invoices_import_v1'::regtype),
    ('recordCollectionFailure','record_collection_failure',
      'ops.economics_collection_failure_import_v1'::regtype)
  ) AS branch(operation_id,branch_name,branch_type)
  WHERE operation_id=v_operation_id;
  IF v_branch_name IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_OPERATION_KIND_INVALID'
      USING ERRCODE='22023';
  END IF;
  v_branch:=ops.economics_compile_composite_json_v1(
    p_operation-'operationId',v_branch_type
  );
  v_outer:=jsonb_build_object(
    'import_kind',v_operation_id,v_branch_name,v_branch
  );
  BEGIN
    v_result:=jsonb_populate_record(
      NULL::ops.economics_import_operation_v1,v_outer
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ECONOMICS_OPERATION_TYPED_CAST_INVALID'
      USING ERRCODE='22023';
  END;
  IF NOT ops.economics_import_operation_v1_is_valid(v_result) THEN
    RAISE EXCEPTION 'ECONOMICS_OPERATION_SEMANTIC_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN v_result;
END
$$;
ALTER FUNCTION ops.compile_economics_import_operation_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.compile_economics_import_operation_v1(jsonb)
  FROM PUBLIC;

CREATE FUNCTION ops.compile_economics_import_draft_v1(
  p_draft jsonb,
  p_actor uuid
) RETURNS ops.economics_import_compiled_draft_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,raw,extensions,pg_temp
AS $$
DECLARE
  v_ids uuid[];
  v_locked_digests char(64)[];
  v_public_digests text[];
  v_locked_distinct text[];
  v_operation ops.economics_import_operation_v1;
  v_operation_canonical bytea;
  v_operation_digest char(64);
  v_evidence_set_digest char(64);
  v_import_policy_digest char(64);
  v_as_of timestamptz;
  v_content_digest char(64);
  v_detail jsonb;
  v_detail_canonical bytea;
  v_detail_digest char(64);
  v_proposer_capabilities char(64);
  v_reviewer_capabilities char(64);
  v_requires_oversight boolean:=false;
  v_result ops.economics_import_compiled_draft_v1;
  v_allowed_states text[];
  v_from_state_key_count bigint;
  v_to_state_key_count bigint;
BEGIN
  IF session_user<>'gurine_control_api' OR current_user<>'gurine_migrator'
     OR p_actor IS NULL OR p_draft IS NULL
     OR jsonb_typeof(p_draft)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_draft))<>9
     OR NOT p_draft ?& ARRAY[
       'schemaVersion','kind','target','rationale','effect','operation',
       'sourceEvidenceDigests','importPolicyDigest','asOf'
     ]
     OR p_draft->>'schemaVersion'<>'action-payload.v1'
     OR p_draft->>'kind'<>'ECONOMICS_IMPORT' THEN
    RAISE EXCEPTION 'ECONOMICS_DRAFT_WIRE_INVALID'
      USING ERRCODE='22023';
  END IF;
  IF jsonb_typeof(p_draft->'target')<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_draft->'target'))<>3
     OR NOT (p_draft->'target') ?& ARRAY[
       'targetType','targetId','expectedVersion'
     ]
     OR p_draft#>>'{target,targetType}'<>'ECONOMICS_IMPORT'
     OR length(COALESCE(p_draft#>>'{target,targetId}','')) NOT BETWEEN 1 AND 200
     OR p_draft#>'{target,expectedVersion}'<>'null'::jsonb THEN
    RAISE EXCEPTION 'ECONOMICS_TARGET_WIRE_INVALID'
      USING ERRCODE='22023';
  END IF;
  IF jsonb_typeof(p_draft->'rationale')<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_draft->'rationale'))<>5
     OR NOT (p_draft->'rationale') ?& ARRAY[
       'summary','evidenceSegmentIds','unknowns','alternativesConsidered',
       'riskNote'
     ]
     OR length(COALESCE(p_draft#>>'{rationale,summary}','')) NOT BETWEEN 1 AND 4000
     OR length(COALESCE(p_draft#>>'{rationale,riskNote}','')) NOT BETWEEN 1 AND 4000
     OR jsonb_typeof(p_draft#>'{rationale,evidenceSegmentIds}')<>'array'
     OR jsonb_array_length(p_draft#>'{rationale,evidenceSegmentIds}')
       NOT BETWEEN 1 AND 1000
     OR jsonb_typeof(p_draft#>'{rationale,unknowns}')<>'array'
     OR jsonb_array_length(p_draft#>'{rationale,unknowns}')>50
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_draft#>'{rationale,unknowns}') value
       WHERE jsonb_typeof(value)<>'string'
         OR length(value#>>'{}') NOT BETWEEN 1 AND 2000
     )
     OR jsonb_typeof(p_draft#>'{rationale,alternativesConsidered}')<>'array'
     OR jsonb_array_length(
       p_draft#>'{rationale,alternativesConsidered}'
     )>20
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(
         p_draft#>'{rationale,alternativesConsidered}'
       ) value WHERE jsonb_typeof(value)<>'string'
         OR length(value#>>'{}') NOT BETWEEN 1 AND 2000
     ) THEN
    RAISE EXCEPTION 'ECONOMICS_RATIONALE_WIRE_INVALID'
      USING ERRCODE='22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(
      p_draft#>'{rationale,evidenceSegmentIds}'
    ) value WHERE jsonb_typeof(value)<>'string'
      OR (value#>>'{}')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  ) THEN
    RAISE EXCEPTION 'ECONOMICS_EVIDENCE_ID_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT array_agg((value#>>'{}')::uuid ORDER BY ordinality)
    INTO v_ids
  FROM jsonb_array_elements(
    p_draft#>'{rationale,evidenceSegmentIds}'
  ) WITH ORDINALITY AS evidence(value,ordinality);
  IF NOT ops.economics_uuid_array_is_sorted_unique_v1(v_ids) THEN
    RAISE EXCEPTION 'ECONOMICS_EVIDENCE_ID_SET_INVALID'
      USING ERRCODE='22023';
  END IF;
  IF jsonb_typeof(p_draft->'sourceEvidenceDigests')<>'array'
     OR jsonb_array_length(p_draft->'sourceEvidenceDigests')<1
     OR jsonb_array_length(p_draft->'sourceEvidenceDigests')
       >cardinality(v_ids)
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_draft->'sourceEvidenceDigests') value
       WHERE jsonb_typeof(value)<>'string'
         OR (value#>>'{}')!~'^[0-9a-f]{64}$'
     ) THEN
    RAISE EXCEPTION 'ECONOMICS_EVIDENCE_DIGEST_SET_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT array_agg(value#>>'{}' ORDER BY ordinality)
    INTO v_public_digests
  FROM jsonb_array_elements(p_draft->'sourceEvidenceDigests')
    WITH ORDINALITY AS digest(value,ordinality);
  IF v_public_digests IS DISTINCT FROM ARRAY(
    SELECT DISTINCT value FROM unnest(v_public_digests) AS digest(value)
    ORDER BY value COLLATE "C"
  ) THEN
    RAISE EXCEPTION 'ECONOMICS_EVIDENCE_DIGEST_SET_INVALID'
      USING ERRCODE='22023';
  END IF;
  IF COALESCE(p_draft->>'importPolicyDigest','')!~'^[0-9a-f]{64}$'
     OR COALESCE(p_draft->>'asOf','')!~
       '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' THEN
    RAISE EXCEPTION 'ECONOMICS_DRAFT_AUTHORITY_WIRE_INVALID'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_as_of:=(p_draft->>'asOf')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ECONOMICS_DRAFT_AS_OF_INVALID'
      USING ERRCODE='22023';
  END;

  PERFORM 1 FROM raw.evidence_segments AS evidence
  WHERE evidence.id=ANY(v_ids) ORDER BY evidence.id FOR SHARE;
  SELECT array_agg(evidence.segment_digest ORDER BY evidence.id)
    INTO v_locked_digests
  FROM raw.evidence_segments AS evidence WHERE evidence.id=ANY(v_ids);
  IF cardinality(v_locked_digests) IS DISTINCT FROM cardinality(v_ids) THEN
    RAISE EXCEPTION 'ECONOMICS_EVIDENCE_NOT_FOUND'
      USING ERRCODE='22023';
  END IF;
  SELECT array_agg(value ORDER BY value COLLATE "C") INTO v_locked_distinct
  FROM (
    SELECT DISTINCT btrim(digest::text) AS value
    FROM unnest(v_locked_digests) AS locked(digest)
  ) AS distinct_digest;
  IF v_public_digests IS DISTINCT FROM v_locked_distinct THEN
    RAISE EXCEPTION 'ECONOMICS_EVIDENCE_DIGEST_MISMATCH'
      USING ERRCODE='22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM ops.users AS actor
    WHERE actor.id=p_actor AND actor.status='ACTIVE'
  ) OR (
    SELECT count(DISTINCT capability.capability_code)
    FROM ops.user_roles AS binding
    JOIN ops.role_capabilities AS capability
      ON capability.role_id=binding.role_id
    WHERE binding.user_id=p_actor AND binding.revoked_at IS NULL
      AND (binding.expires_at IS NULL OR binding.expires_at>clock_timestamp())
      AND capability.capability_code IN ('actions.propose','budgets.manage')
  )<>2 THEN
    RAISE EXCEPTION 'ECONOMICS_PROPOSER_CAPABILITY_DENIED'
      USING ERRCODE='42501';
  END IF;

  v_operation:=ops.compile_economics_import_operation_v1(
    p_draft->'operation'
  );
  v_operation_canonical:=ops.canonical_jsonb_v1(to_jsonb(v_operation));
  v_operation_digest:=encode(
    extensions.digest(v_operation_canonical,'sha256'),'hex'
  );
  v_evidence_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','economics-import-evidence-set.v1',
      'segmentIds',to_jsonb(v_ids),
      'segmentDigests',to_jsonb(v_locked_digests)
    )),'sha256'
  ),'hex');
  v_import_policy_digest:=(p_draft->>'importPolicyDigest')::char(64);
  v_content_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(p_draft),'sha256'
  ),'hex');
  v_proposer_capabilities:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','economics-import-capability-set.v1',
      'capabilities',jsonb_build_array('actions.propose','budgets.manage')
    )),'sha256'
  ),'hex');
  v_reviewer_capabilities:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','economics-import-capability-set.v1',
      'capabilities',jsonb_build_array('actions.review','budgets.manage')
    )),'sha256'
  ),'hex');
  v_detail:=jsonb_build_object(
    'schemaVersion','economics-import-detail.v1',
    'detailKind','ECONOMICS_IMPORT',
    'operationId',(v_operation).import_kind,
    'operation',to_jsonb(v_operation),
    'operationDigest',btrim(v_operation_digest),
    'sourceEvidenceSegmentIds',to_jsonb(v_ids),
    'sourceEvidenceDigests',to_jsonb(v_locked_digests),
    'sourceEvidenceSetDigest',btrim(v_evidence_set_digest),
    'importPolicyDigest',btrim(v_import_policy_digest),
    'asOf',v_as_of,
    'creatorActorId',p_actor,
    'proposerCapabilitySetDigest',btrim(v_proposer_capabilities),
    'reviewerCapabilitySetDigest',btrim(v_reviewer_capabilities)
  );
  v_detail_canonical:=ops.canonical_jsonb_v1(v_detail);
  v_detail_digest:=encode(
    extensions.digest(v_detail_canonical,'sha256'),'hex'
  );
  v_requires_oversight:=CASE (v_operation).import_kind
    WHEN 'createTariffVersion' THEN
      ((v_operation).create_tariff_version)
        .expected_projected_p75_variable_gross_margin_basis_points
      <((v_operation).create_tariff_version)
        .expected_required_variable_gross_margin_basis_points
    WHEN 'recordInvoice' THEN EXISTS (
      SELECT 1 FROM unnest(((v_operation).record_invoice).discounts) source
      WHERE (source).resolution='APPEND'
        AND ((source).append_value)
          .projected_margin_after_discount_basis_points
        <((source).append_value)
          .required_variable_gross_margin_basis_points
    )
    ELSE false
  END;

  IF jsonb_typeof(p_draft->'effect')<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_draft->'effect'))<>6
     OR NOT (p_draft->'effect') ?& ARRAY[
       'effectClass','fromState','toState','externalSideEffect','reversible',
       'expectedOutcome'
     ]
     OR jsonb_typeof(p_draft#>'{effect,fromState}')<>'object'
     OR jsonb_typeof(p_draft#>'{effect,toState}')<>'object'
     OR NOT (p_draft#>'{effect,fromState}') ?& ARRAY['aggregate','state']
     OR NOT (p_draft#>'{effect,toState}') ?& ARRAY['aggregate','state']
     OR p_draft#>>'{effect,effectClass}'<>'INTERNAL_MATERIALIZATION'
     OR p_draft#>'{effect,externalSideEffect}'<>'false'::jsonb
     OR jsonb_typeof(p_draft#>'{effect,reversible}')<>'boolean'
     OR length(COALESCE(p_draft#>>'{effect,expectedOutcome}',''))
       NOT BETWEEN 1 AND 4000
     OR p_draft#>>'{effect,fromState,aggregate}'<>'ECONOMICS_IMPORT'
     OR p_draft#>>'{effect,fromState,state}'<>'UNRECORDED'
     OR p_draft#>>'{effect,toState,aggregate}'<>'ECONOMICS_IMPORT' THEN
    RAISE EXCEPTION 'ECONOMICS_EFFECT_WIRE_INVALID'
      USING ERRCODE='22023';
  END IF;
  v_allowed_states:=CASE (v_operation).import_kind
    WHEN 'recordCommercialQualification' THEN ARRAY['RECORDED','REPLACED','REVERSED']
    WHEN 'importCostAllocationClose' THEN ARRAY['RECORDED','REPLACED']
    WHEN 'createTariffVersion' THEN ARRAY['RECORDED']
    WHEN 'recordCommercialContractPeriod' THEN ARRAY['RECORDED','REPLACED']
    WHEN 'recordUsageWindow' THEN ARRAY['RECORDED','REPLACED','REVERSED']
    WHEN 'recordInvoice' THEN ARRAY['RECORDED','REPLACED']
    WHEN 'recordRevenue' THEN ARRAY['RECORDED']
    WHEN 'recordAccountingCorrection' THEN ARRAY['RECORDED','REVERSED']
    WHEN 'recordCashApplication' THEN ARRAY['RECORDED','REPLACED','REVERSED']
    WHEN 'recordTaxInvoiceIssuance' THEN ARRAY['RECORDED','REPLACED','REVERSED']
    WHEN 'recordCollectionFailure' THEN ARRAY['REVIEW_TASK_CREATED']
  END;
  SELECT count(*) INTO v_from_state_key_count
  FROM jsonb_object_keys(p_draft#>'{effect,fromState}');
  SELECT count(*) INTO v_to_state_key_count
  FROM jsonb_object_keys(p_draft#>'{effect,toState}');
  IF NOT COALESCE(p_draft#>>'{effect,toState,state}'=ANY(v_allowed_states),false)
     OR v_from_state_key_count<>2 OR v_to_state_key_count<>2 THEN
    RAISE EXCEPTION 'ECONOMICS_EFFECT_DISPOSITION_INVALID'
      USING ERRCODE='22023';
  END IF;
  v_result:=(
    (v_operation).import_kind,v_operation,v_operation_canonical,
    v_operation_digest,v_ids,v_locked_digests,v_evidence_set_digest,
    v_import_policy_digest,v_as_of,v_content_digest,v_detail_canonical,
    v_detail_digest,v_proposer_capabilities,v_reviewer_capabilities,
    v_requires_oversight
  )::ops.economics_import_compiled_draft_v1;
  RETURN v_result;
END
$$;
ALTER FUNCTION ops.compile_economics_import_draft_v1(jsonb,uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.compile_economics_import_draft_v1(jsonb,uuid)
  FROM PUBLIC;

CREATE TYPE ops.economics_import_governance_v1 AS (
  proposer_id uuid,
  approver_id uuid,
  decision_digest char(64),
  oversight_approver_id uuid,
  oversight_decision_digest char(64),
  counted_decision_count bigint,
  action_detail_digest char(64)
);
REVOKE ALL ON TYPE ops.economics_import_governance_v1 FROM PUBLIC;

CREATE FUNCTION ops.economics_import_governance_v1(
  p_execution_id uuid,
  p_generation bigint,
  p_approval_digest char(64)
) RETURNS ops.economics_import_governance_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_auth ops.execution_authorizations%ROWTYPE;
  v_proposal ops.action_proposals%ROWTYPE;
  v_detail ops.action_approval_economics_import_details%ROWTYPE;
  v_approver_id uuid;
  v_decision_digest char(64);
  v_oversight_id uuid;
  v_oversight_digest char(64);
  v_count bigint;
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_GOVERNANCE_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_auth
  FROM ops.execution_authorizations
  WHERE execution_id=p_execution_id AND generation=p_generation
  FOR SHARE;
  IF NOT FOUND OR v_auth.action_kind<>'ECONOMICS_IMPORT'
     OR v_auth.approval_digest<>p_approval_digest
     OR v_auth.executor_id<>'private.ExecuteEconomicsImport'
     OR v_auth.transport<>'PRIVATE_APPLICATION_COMMAND'
     OR v_auth.required_capability<>'economics.import'
     OR v_auth.effect_boundary<>'DATABASE_ONLY'
     OR v_auth.cost_class<>'NO_PAID_EGRESS' THEN
    RAISE EXCEPTION 'ECONOMICS_GOVERNANCE_BINDING_INVALID'
      USING ERRCODE='P6E10';
  END IF;
  SELECT * INTO v_proposal FROM ops.action_proposals
  WHERE id=v_auth.proposal_id FOR SHARE;
  SELECT * INTO v_detail FROM ops.action_approval_economics_import_details
  WHERE proposal_id=v_auth.proposal_id
    AND proposal_version=v_auth.proposal_version FOR SHARE;
  IF v_proposal.id IS NULL OR v_detail.proposal_id IS NULL
     OR v_proposal.action_kind<>'ECONOMICS_IMPORT'
     OR v_proposal.created_by<>v_detail.creator_actor_id
     OR v_detail.approval_digest<>p_approval_digest THEN
    RAISE EXCEPTION 'ECONOMICS_GOVERNANCE_BINDING_INVALID'
      USING ERRCODE='P6E10';
  END IF;

  SELECT decision.actor_id,decision.receipt_digest
  INTO v_approver_id,v_decision_digest
  FROM ops.action_decisions AS decision
  JOIN ops.action_review_assignments AS assignment
    ON assignment.id=decision.assignment_id
  WHERE decision.id=ANY(v_auth.counted_decision_ids)
    AND decision.proposal_id=v_auth.proposal_id
    AND decision.proposal_version=v_auth.proposal_version
    AND decision.approval_digest=p_approval_digest
    AND decision.record_kind='DECISION'
    AND decision.decision_kind='APPROVE'
    AND decision.counts_toward_quorum
    AND decision.assurance='STEP_UP'
    AND assignment.slot_id='economics_reviewer'
    AND assignment.reviewer_id=decision.actor_id
    AND assignment.state='COMPLETED'
  ORDER BY decision.id
  LIMIT 1;
  IF v_approver_id IS NULL OR v_approver_id=v_proposal.created_by THEN
    RAISE EXCEPTION 'ECONOMICS_GOVERNANCE_PRIMARY_REVIEW_INVALID'
      USING ERRCODE='P6E10';
  END IF;
  SELECT decision.actor_id,decision.receipt_digest
  INTO v_oversight_id,v_oversight_digest
  FROM ops.action_decisions AS decision
  JOIN ops.action_review_assignments AS assignment
    ON assignment.id=decision.assignment_id
  WHERE decision.id=ANY(v_auth.counted_decision_ids)
    AND decision.proposal_id=v_auth.proposal_id
    AND decision.proposal_version=v_auth.proposal_version
    AND decision.approval_digest=p_approval_digest
    AND decision.record_kind='DECISION'
    AND decision.decision_kind='APPROVE'
    AND decision.counts_toward_quorum
    AND decision.assurance='STEP_UP'
    AND assignment.slot_id='economics_oversight'
    AND assignment.reviewer_id=decision.actor_id
    AND assignment.state='COMPLETED'
  ORDER BY decision.id
  LIMIT 1;
  SELECT count(*) INTO v_count
  FROM ops.action_decisions AS decision
  WHERE decision.id=ANY(v_auth.counted_decision_ids)
    AND decision.proposal_id=v_auth.proposal_id
    AND decision.proposal_version=v_auth.proposal_version
    AND decision.approval_digest=p_approval_digest
    AND decision.record_kind='DECISION'
    AND decision.decision_kind='APPROVE'
    AND decision.counts_toward_quorum
    AND decision.assurance='STEP_UP';
  RETURN (
    v_proposal.created_by,v_approver_id,v_decision_digest,
    v_oversight_id,v_oversight_digest,v_count,v_detail.action_detail_digest
  )::ops.economics_import_governance_v1;
END
$$;
ALTER FUNCTION ops.economics_import_governance_v1(
  uuid,bigint,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_import_governance_v1(
  uuid,bigint,char(64)
) FROM PUBLIC;

CREATE FUNCTION ops.economics_import_outbox_digest_v1(
  p_event_id uuid
) RETURNS char(64)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
  SELECT ops.economics_import_row_digest_v1(
    'economics-notification-outbox-event.v1',to_jsonb(event),
    ARRAY['available_at','published_at','attempt_count','last_error']
  )
  FROM ops.outbox AS event WHERE event.id=p_event_id
$$;
ALTER FUNCTION ops.economics_import_outbox_digest_v1(uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_import_outbox_digest_v1(uuid)
  FROM PUBLIC;

CREATE FUNCTION ops.finalize_economics_import_apply_v1(
  p_operation_id text,
  p_result_rows ops.economics_import_result_row_v1[],
  p_primary ops.economics_import_result_row_v1,
  p_notification_outbox_event_id uuid,
  p_applied_at timestamptz
) RETURNS ops.economics_import_apply_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_rows ops.economics_import_result_row_v1[];
  v_digest char(64);
  v_result ops.economics_import_apply_receipt_v1;
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator'
     OR p_result_rows IS NULL OR cardinality(p_result_rows)=0
     OR p_primary IS NULL OR p_applied_at IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_RESULT_SET_INVALID' USING ERRCODE='P6E10';
  END IF;
  SELECT array_agg(
    ROW(
      row_value.resource_kind,row_value.resource_id,
      row_value.resource_version,row_value.resource_digest
    )::ops.economics_import_result_row_v1
    ORDER BY row_value.resource_kind,row_value.resource_id
  ) INTO v_rows
  FROM unnest(p_result_rows) AS row_value;
  IF EXISTS (
    SELECT 1
    FROM unnest(v_rows) WITH ORDINALITY AS row_value(
      resource_kind,resource_id,resource_version,resource_digest,ordinality
    )
    JOIN unnest(v_rows) WITH ORDINALITY AS duplicate(
      resource_kind,resource_id,resource_version,resource_digest,ordinality
    ) ON duplicate.resource_kind=row_value.resource_kind
      AND duplicate.resource_id=row_value.resource_id
      AND duplicate.ordinality<>row_value.ordinality
  ) THEN
    RAISE EXCEPTION 'ECONOMICS_RESULT_SET_DUPLICATE'
      USING ERRCODE='P6E10';
  END IF;
  v_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','economics-import-result-set.v1',
      'operationId',p_operation_id,'rows',to_jsonb(v_rows)
    )),'sha256'
  ),'hex');
  v_result:=(
    p_operation_id,v_rows,cardinality(v_rows),v_digest,
    (p_primary).resource_kind,(p_primary).resource_id,
    (p_primary).resource_version,(p_primary).resource_digest,
    p_notification_outbox_event_id,p_applied_at
  )::ops.economics_import_apply_receipt_v1;
  IF NOT ops.economics_import_apply_receipt_v1_is_valid(v_result) THEN
    RAISE EXCEPTION 'ECONOMICS_RESULT_RECEIPT_INVALID'
      USING ERRCODE='P6E10';
  END IF;
  RETURN v_result;
END
$$;
ALTER FUNCTION ops.finalize_economics_import_apply_v1(
  text,ops.economics_import_result_row_v1[],
  ops.economics_import_result_row_v1,uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.finalize_economics_import_apply_v1(
  text,ops.economics_import_result_row_v1[],
  ops.economics_import_result_row_v1,uuid,timestamptz
) FROM PUBLIC;

-- The legacy row writers remain exact relation-specific mutators, but their
-- historical SERIALIZABLE check is redundant inside the lock-complete apply
-- transaction.  No non-importer can use this private idempotency helper.
CREATE OR REPLACE FUNCTION ops.business_write_begin_v1(
  p_kind text,p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_key text:=NULLIF(btrim(p_payload->>'idempotencyKey'),'');
  v_key_hash char(64);
  v_request_hash char(64);
  v_existing ops.idempotency_keys%ROWTYPE;
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR v_key IS NULL OR p_kind IS NULL
     OR p_kind!~'^[A-Z][A-Z0-9_]{1,63}$' THEN
    RAISE EXCEPTION 'BUSINESS_ROW_INVALID' USING ERRCODE='22023';
  END IF;
  v_key_hash:=encode(extensions.digest(convert_to(v_key,'UTF8'),'sha256'),'hex');
  v_request_hash:=encode(
    extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'),'hex'
  );
  SELECT * INTO v_existing FROM ops.idempotency_keys
  WHERE scope='ECONOMICS.RECORD_'||p_kind AND key_hash=v_key_hash
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_hash<>v_request_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='40001';
    END IF;
    RETURN v_existing.response_body||jsonb_build_object(
      'idempotencyReplay',true
    );
  END IF;
  RETURN NULL;
END
$$;
ALTER FUNCTION ops.business_write_begin_v1(text,jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.business_write_begin_v1(text,jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.record_invoice_line_fact_v1(
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_replay jsonb;
  v_row ops.invoice_line_facts%ROWTYPE;
BEGIN
  v_replay:=ops.business_write_begin_v1('INVOICE_LINE_FACT',p_payload);
  IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  v_row:=jsonb_populate_record(NULL::ops.invoice_line_facts,p_payload);
  PERFORM ops.assert_business_payload_keys_v1(p_payload,to_jsonb(v_row));
  IF v_row.id IS NULL OR v_row.line_digest!~'^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.invoice_line_facts SELECT v_row.*;
  RETURN ops.business_write_finish_v1(
    'INVOICE_LINE_FACT',p_payload,v_row.id::text,v_row.line_digest
  );
END
$$;
ALTER FUNCTION ops.record_invoice_line_fact_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_invoice_line_fact_v1(jsonb)
  FROM PUBLIC,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_public_projector,gurine_public_api,
  gurine_submission_api,gurine_ingest_worker,gurine_notification_worker,
  gurine_scheduler,gurine_document_extractor,gurine_identity_api,
  gurine_auditor,gurine_billing_gateway,gurine_economics_importer;

CREATE TYPE ops.economics_import_effect_v1 AS (
  result_rows ops.economics_import_result_row_v1[],
  primary_result ops.economics_import_result_row_v1,
  notification_outbox_event_id uuid
);
REVOKE ALL ON TYPE ops.economics_import_effect_v1 FROM PUBLIC;

-- 0030 removed its generic caller-JSON dispatcher but retained two wrappers
-- that can bypass the R6e proposal, independent decision, authorization and
-- typed owner boundaries.  Keep those definitions only as migration-era
-- private details; no runtime principal may execute them directly.
REVOKE ALL ON FUNCTION
  ops.record_outcome_fact_v1(jsonb),
  ops.record_paid_evidence_packet_v1(jsonb)
FROM PUBLIC,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_public_projector,gurine_public_api,
  gurine_submission_api,gurine_ingest_worker,gurine_notification_worker,
  gurine_scheduler,gurine_document_extractor,gurine_identity_api,
  gurine_auditor,gurine_billing_gateway,gurine_economics_importer;

CREATE OR REPLACE FUNCTION ops.record_commercial_qualification_receipt_v1(
  p_input ops.commercial_qualification_receipt_input_v1,
  p_idempotency_key text
) RETURNS ops.economics_mutation_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_id uuid:=CASE WHEN (p_input).receipt_effect='ORIGINAL'
    THEN (p_input).root_receipt_id ELSE gen_random_uuid() END;
  v_row ops.commercial_qualification_receipts%ROWTYPE;
  v_digest char(64);
  v_body jsonb;
  v_response_digest char(64);
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator'
     OR NULLIF(btrim(p_idempotency_key),'') IS NULL
     OR p_input IS NULL THEN
    RAISE EXCEPTION 'COMMERCIAL_QUALIFICATION_INVALID'
      USING ERRCODE='22023';
  END IF;
  v_row:=jsonb_populate_record(
    NULL::ops.commercial_qualification_receipts,
    to_jsonb(p_input)-'receipt_digest'||jsonb_build_object(
      'id',v_id,'recorded_at',v_now
    )
  );
  v_digest:=ops.economics_import_row_digest_v1(
    'commercial-qualification-receipt.v1',to_jsonb(v_row),
    ARRAY['receipt_digest','recorded_at']
  );
  v_row:=jsonb_populate_record(
    v_row,jsonb_build_object('receipt_digest',btrim(v_digest::text))
  );
  INSERT INTO ops.commercial_qualification_receipts SELECT v_row.*;
  v_body:=jsonb_build_object(
    'resourceId',v_id,'resourceType','COMMERCIAL_QUALIFICATION_RECEIPT',
    'resourceVersion',(p_input).revision,
    'receiptDigest',btrim(v_digest::text),'committedAt',v_now
  );
  v_response_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_body),'sha256'
  ),'hex');
  RETURN (
    v_id,'COMMERCIAL_QUALIFICATION_RECEIPT',v_id,(p_input).revision,
    v_digest,NULL,NULL,201,'application/json',
    ops.canonical_jsonb_v1(v_body),v_response_digest,v_digest,v_now,false
  )::ops.economics_mutation_receipt_v1;
END
$$;
ALTER FUNCTION ops.record_commercial_qualification_receipt_v1(
  ops.commercial_qualification_receipt_input_v1,text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_commercial_qualification_receipt_v1(
  ops.commercial_qualification_receipt_input_v1,text
) FROM PUBLIC,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_public_projector,gurine_public_api,
  gurine_submission_api,gurine_ingest_worker,gurine_notification_worker,
  gurine_scheduler,gurine_document_extractor,gurine_identity_api,
  gurine_auditor,gurine_billing_gateway,gurine_economics_importer;

CREATE FUNCTION ops.apply_economics_qualification_v1(
  p_value ops.economics_qualification_import_v1,
  p_execution_id uuid
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_source ops.economics_acquisition_source_import_v1;
  v_append ops.acquisition_source_receipt_input_v1;
  v_source_row ops.acquisition_source_receipts%ROWTYPE;
  v_source_result ops.economics_import_result_row_v1;
  v_qualification_input ops.commercial_qualification_receipt_input_v1;
  v_receipt ops.economics_mutation_receipt_v1;
  v_qualification_result ops.economics_import_result_row_v1;
  v_results ops.economics_import_result_row_v1[]:='{}';
  v_id uuid;
  v_digest char(64);
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' OR p_value IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_QUALIFICATION_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  v_source:=(p_value).acquisition_source;
  IF (v_source).resolution='EXISTING' THEN
    SELECT * INTO v_source_row FROM ops.acquisition_source_receipts
    WHERE id=(v_source).existing_receipt_id
      AND revision=(v_source).existing_receipt_revision
      AND receipt_digest=(v_source).existing_receipt_digest
    FOR UPDATE;
    IF NOT FOUND
       OR v_source_row.id IS DISTINCT FROM (p_value).acquisition_source_receipt_id
       OR v_source_row.receipt_digest IS DISTINCT FROM
          (p_value).acquisition_source_receipt_digest
       OR v_source_row.deployment_id<>(p_value).deployment_id
       OR v_source_row.organization_id<>(p_value).organization_id
       OR v_source_row.valid_from>(p_value).first_qualified_at
       OR v_source_row.valid_until<=(p_value).first_qualified_at
       OR EXISTS (
         SELECT 1 FROM ops.acquisition_source_receipts later
         WHERE later.supersedes_receipt_id=v_source_row.id
       ) THEN
      RAISE EXCEPTION 'ECONOMICS_ACQUISITION_SOURCE_STALE'
        USING ERRCODE='P6E10';
    END IF;
  ELSE
    v_append:=(v_source).append_value;
    v_id:=CASE WHEN (v_append).revision=1
      THEN (v_append).root_receipt_id ELSE gen_random_uuid() END;
    IF (v_append).revision=1 THEN
      IF (v_source).expected_head_id IS NOT NULL OR EXISTS (
        SELECT 1 FROM ops.acquisition_source_receipts
        WHERE root_receipt_id=(v_append).root_receipt_id
      ) THEN
        RAISE EXCEPTION 'ECONOMICS_ACQUISITION_SOURCE_HEAD_CONFLICT'
          USING ERRCODE='P6E10';
      END IF;
    ELSE
      SELECT * INTO v_source_row FROM ops.acquisition_source_receipts
      WHERE id=(v_source).expected_head_id
        AND revision=(v_source).expected_head_revision
        AND receipt_digest=(v_source).expected_head_digest
        AND id=(v_append).supersedes_receipt_id
        AND root_receipt_id=(v_append).root_receipt_id
      FOR UPDATE;
      IF NOT FOUND OR EXISTS (
        SELECT 1 FROM ops.acquisition_source_receipts later
        WHERE later.supersedes_receipt_id=v_source_row.id
      ) THEN
        RAISE EXCEPTION 'ECONOMICS_ACQUISITION_SOURCE_HEAD_CONFLICT'
          USING ERRCODE='P6E10';
      END IF;
    END IF;
    v_source_row:=jsonb_populate_record(
      NULL::ops.acquisition_source_receipts,
      to_jsonb(v_append)-'receipt_digest'||jsonb_build_object(
        'id',v_id,'created_at',v_now
      )
    );
    v_digest:=ops.economics_import_row_digest_v1(
      'acquisition-source-receipt.v1',to_jsonb(v_source_row),
      ARRAY['receipt_digest','created_at']
    );
    IF (v_append).receipt_digest IS DISTINCT FROM v_digest THEN
      RAISE EXCEPTION 'ECONOMICS_ACQUISITION_SOURCE_DIGEST_MISMATCH'
        USING ERRCODE='P6E10';
    END IF;
    v_source_row:=jsonb_populate_record(
      v_source_row,jsonb_build_object('receipt_digest',btrim(v_digest::text))
    );
    v_source_result:=ops.insert_acquisition_source_receipt_v1(v_source_row);
    v_results:=array_append(v_results,v_source_result);
  END IF;

  IF (p_value).revision=1 THEN
    IF (p_value).expected_head_id IS NOT NULL OR EXISTS (
      SELECT 1 FROM ops.commercial_qualification_receipts
      WHERE root_receipt_id=(p_value).root_receipt_id
    ) THEN
      RAISE EXCEPTION 'ECONOMICS_QUALIFICATION_HEAD_CONFLICT'
        USING ERRCODE='P6E10';
    END IF;
  ELSE
    PERFORM 1 FROM ops.commercial_qualification_receipts head
    WHERE head.id=(p_value).expected_head_id
      AND head.revision=(p_value).expected_head_revision
      AND head.receipt_digest=(p_value).expected_head_digest
      AND head.id=(p_value).supersedes_receipt_id
      AND head.root_receipt_id=(p_value).root_receipt_id
      AND NOT EXISTS (
        SELECT 1 FROM ops.commercial_qualification_receipts later
        WHERE later.supersedes_receipt_id=head.id
      )
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'ECONOMICS_QUALIFICATION_HEAD_CONFLICT'
        USING ERRCODE='P6E10';
    END IF;
  END IF;
  v_qualification_input:=jsonb_populate_record(
    NULL::ops.commercial_qualification_receipt_input_v1,
    to_jsonb(p_value)-ARRAY[
      'expected_head_id','expected_head_revision','expected_head_digest',
      'acquisition_source'
    ]||jsonb_build_object(
      'acquisition_source_receipt_id',v_source_row.id,
      'acquisition_source_receipt_digest',btrim(v_source_row.receipt_digest),
      'receipt_digest',NULL
    )
  );
  v_receipt:=ops.record_commercial_qualification_receipt_v1(
    v_qualification_input,
    'r6e-economics:'||p_execution_id::text||':qualification'
  );
  v_qualification_result:=(
    'COMMERCIAL_QUALIFICATION_RECEIPT',(v_receipt).resource_id,
    (v_receipt).resource_version,(v_receipt).resource_digest
  )::ops.economics_import_result_row_v1;
  v_results:=array_append(v_results,v_qualification_result);
  RETURN (v_results,v_qualification_result,NULL)
    ::ops.economics_import_effect_v1;
END
$$;
ALTER FUNCTION ops.apply_economics_qualification_v1(
  ops.economics_qualification_import_v1,uuid
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_qualification_v1(
  ops.economics_qualification_import_v1,uuid
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_cost_close_v1(
  p_value ops.economics_cost_close_import_v1,
  p_governance ops.economics_import_governance_v1
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_period ops.economics_cost_period_import_v1:=(p_value).period;
  v_line ops.economics_cost_line_import_v1;
  v_source ops.economics_fx_rate_source_import_v1;
  v_append ops.economics_fx_rate_append_v1;
  v_fx_row ops.fx_rate_facts%ROWTYPE;
  v_cost_row ops.cost_allocations%ROWTYPE;
  v_period_head ops.cost_allocations%ROWTYPE;
  v_result ops.economics_import_result_row_v1;
  v_primary ops.economics_import_result_row_v1;
  v_results ops.economics_import_result_row_v1[]:='{}';
  v_resolved_fx_ids uuid[]:='{}';
  v_id uuid;
  v_digest char(64);
  v_allocation_set_digest char(64);
  v_close_digest char(64);
  v_json jsonb;
  v_fx_id uuid;
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator' OR p_value IS NULL
     OR p_governance IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_COST_CLOSE_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  FOREACH v_source IN ARRAY (p_value).fx_rates LOOP
    IF (v_source).resolution='EXISTING' THEN
      SELECT * INTO v_fx_row FROM ops.fx_rate_facts
      WHERE id=(v_source).existing_rate_id
        AND revision=(v_source).existing_rate_revision
        AND sha256=(v_source).existing_rate_digest
        AND deployment_id=(v_period).deployment_id
      FOR UPDATE;
      IF NOT FOUND OR EXISTS (
        SELECT 1 FROM ops.fx_rate_facts later
        WHERE later.supersedes_rate_id=v_fx_row.id
      ) THEN
        RAISE EXCEPTION 'ECONOMICS_FX_RATE_HEAD_CONFLICT'
          USING ERRCODE='P6E10';
      END IF;
    ELSE
      v_append:=(v_source).append_value;
      v_id:=CASE WHEN (v_append).revision=1
        THEN (v_append).root_rate_id ELSE gen_random_uuid() END;
      IF (v_append).revision=1 THEN
        IF (v_source).expected_head_id IS NOT NULL OR EXISTS (
          SELECT 1 FROM ops.fx_rate_facts
          WHERE root_rate_id=(v_append).root_rate_id
        ) THEN
          RAISE EXCEPTION 'ECONOMICS_FX_RATE_HEAD_CONFLICT'
            USING ERRCODE='P6E10';
        END IF;
      ELSE
        SELECT * INTO v_fx_row FROM ops.fx_rate_facts
        WHERE id=(v_source).expected_head_id
          AND revision=(v_source).expected_head_revision
          AND sha256=(v_source).expected_head_digest
          AND id=(v_append).supersedes_rate_id
          AND root_rate_id=(v_append).root_rate_id
        FOR UPDATE;
        IF NOT FOUND OR EXISTS (
          SELECT 1 FROM ops.fx_rate_facts later
          WHERE later.supersedes_rate_id=v_fx_row.id
        ) THEN
          RAISE EXCEPTION 'ECONOMICS_FX_RATE_HEAD_CONFLICT'
            USING ERRCODE='P6E10';
        END IF;
      END IF;
      v_json:=to_jsonb(v_append)-ARRAY[
        'expected_record_digest','approver_id','decision_digest'
      ]||jsonb_build_object(
        'id',v_id,'deployment_id',(v_period).deployment_id,
        'approver_id',NULL,'decision_digest',NULL,'created_at',v_now
      );
      IF (v_append).revision>1 THEN
        v_json:=v_json||jsonb_build_object(
          'approver_id',(p_governance).approver_id,
          'decision_digest',btrim((p_governance).decision_digest)
        );
      END IF;
      v_fx_row:=jsonb_populate_record(NULL::ops.fx_rate_facts,v_json);
      v_digest:=ops.economics_import_row_digest_v1(
        'fx-rate-fact.v1',to_jsonb(v_fx_row),ARRAY['sha256','created_at']
      );
      IF (v_append).expected_record_digest IS DISTINCT FROM v_digest THEN
        RAISE EXCEPTION 'ECONOMICS_FX_RATE_DIGEST_MISMATCH'
          USING ERRCODE='P6E10';
      END IF;
      v_fx_row:=jsonb_populate_record(
        v_fx_row,jsonb_build_object('sha256',btrim(v_digest::text))
      );
      v_result:=ops.insert_fx_rate_fact_v1(v_fx_row);
      v_results:=array_append(v_results,v_result);
    END IF;
    v_resolved_fx_ids:=array_append(v_resolved_fx_ids,v_fx_row.id);
  END LOOP;

  v_allocation_set_digest:=ops.economics_import_row_digest_v1(
    'cost-allocation-set.v1',jsonb_build_object(
      'period',to_jsonb(v_period)-ARRAY[
        'expected_allocation_set_digest','close_receipt_digest',
        'expected_head_id','expected_head_version','expected_head_digest'
      ],
      'lines',to_jsonb((p_value).lines),
      'resolvedFxRateIds',to_jsonb(v_resolved_fx_ids)
    ),'{}'::text[]
  );
  IF (v_period).expected_allocation_set_digest
       IS DISTINCT FROM v_allocation_set_digest THEN
    RAISE EXCEPTION 'ECONOMICS_COST_ALLOCATION_SET_DIGEST_MISMATCH'
      USING ERRCODE='P6E10';
  END IF;
  v_close_digest:=ops.economics_import_row_digest_v1(
    'cost-allocation-close.v1',jsonb_build_object(
      'allocationSetDigest',btrim(v_allocation_set_digest::text),
      'closeReceiptId',(v_period).close_receipt_id,
      'closedAt',(v_period).closed_at,
      'periodRevisionId',(v_period).period_revision_id,
      'periodVersion',(v_period).period_version
    ),'{}'::text[]
  );
  IF (v_period).close_receipt_digest IS DISTINCT FROM v_close_digest THEN
    RAISE EXCEPTION 'ECONOMICS_COST_CLOSE_RECEIPT_DIGEST_MISMATCH'
      USING ERRCODE='P6E10';
  END IF;
  IF (v_period).period_version=1 THEN
    IF (v_period).expected_head_id IS NOT NULL OR EXISTS (
      SELECT 1 FROM ops.cost_allocations
      WHERE row_kind='PERIOD'
        AND deployment_id=(v_period).deployment_id
        AND period_start=(v_period).period_start
        AND period_end=(v_period).period_end
        AND currency=(v_period).currency
    ) THEN
      RAISE EXCEPTION 'ECONOMICS_COST_PERIOD_HEAD_CONFLICT'
        USING ERRCODE='P6E10';
    END IF;
  ELSE
    SELECT * INTO v_period_head FROM ops.cost_allocations
    WHERE id=(v_period).expected_head_id
      AND row_kind='PERIOD'
      AND period_version=(v_period).expected_head_version
      AND record_digest=(v_period).expected_head_digest
      AND id=(v_period).supersedes_period_revision_id
    FOR UPDATE;
    IF NOT FOUND OR EXISTS (
      SELECT 1 FROM ops.cost_allocations later
      WHERE later.row_kind='PERIOD'
        AND later.supersedes_period_revision_id=v_period_head.id
    ) THEN
      RAISE EXCEPTION 'ECONOMICS_COST_PERIOD_HEAD_CONFLICT'
        USING ERRCODE='P6E10';
    END IF;
  END IF;
  v_json:=jsonb_build_object(
    'id',(v_period).period_revision_id,'row_kind','PERIOD',
    'period_revision_id',(v_period).period_revision_id,
    'period_revision_row_kind','PERIOD',
    'supersedes_period_revision_id',(v_period).supersedes_period_revision_id,
    'supersedes_period_row_kind',CASE
      WHEN (v_period).supersedes_period_revision_id IS NULL THEN NULL
      ELSE 'PERIOD' END,
    'deployment_id',(v_period).deployment_id,
    'accounting_timezone',(v_period).accounting_timezone,
    'accounting_policy_digest',btrim((v_period).accounting_policy_digest),
    'period_start',(v_period).period_start,'period_end',(v_period).period_end,
    'currency',btrim((v_period).currency),'period_version',(v_period).period_version,
    'line_sequence',0,'source_set_digest',btrim((v_period).source_set_digest),
    'pool_set_digest',btrim((v_period).pool_set_digest),
    'driver_set_digest',btrim((v_period).driver_set_digest),
    'correction_set_digest',btrim((v_period).correction_set_digest),
    'allocation_set_digest',btrim(v_allocation_set_digest),
    'captured_cost_count',(v_period).expected_captured_cost_count,
    'expected_cost_count',(v_period).expected_cost_count,
    'cost_capture_state',(v_period).expected_cost_capture_state,
    'cost_capture_coverage',(v_period).expected_cost_capture_coverage,
    'direct_eligible_amount',(v_period).expected_direct_eligible_amount,
    'direct_allocated_amount',(v_period).expected_direct_allocated_amount,
    'captured_cost_amount',(v_period).expected_captured_cost_amount,
    'attributed_cost_amount',(v_period).expected_attributed_cost_amount,
    'unallocated_amount',(v_period).expected_unallocated_amount,
    'direct_coverage',(v_period).expected_direct_coverage,
    'total_coverage',(v_period).expected_total_coverage,
    'claim_state',(v_period).expected_claim_state,
    'incomplete_reason_set_digest',(v_period).incomplete_reason_set_digest,
    'unknown_cost_scope_digest',(v_period).unknown_cost_scope_digest,
    'close_receipt_id',(v_period).close_receipt_id,
    'close_receipt_digest',btrim(v_close_digest),
    'closed_at',(v_period).closed_at,'record_class','COMMERCIAL_ACCOUNTING_FACT',
    'schedule_revision',(v_period).schedule_revision,
    'schedule_digest',btrim((v_period).schedule_digest),'recorded_at',v_now
  );
  v_cost_row:=jsonb_populate_record(NULL::ops.cost_allocations,v_json);
  v_digest:=ops.economics_import_row_digest_v1(
    'cost-allocation-period.v1',to_jsonb(v_cost_row),
    ARRAY['record_digest','recorded_at']
  );
  v_cost_row:=jsonb_populate_record(
    v_cost_row,jsonb_build_object('record_digest',btrim(v_digest))
  );
  v_primary:=ops.insert_cost_allocation_v1(v_cost_row);
  v_results:=array_append(v_results,v_primary);

  FOREACH v_line IN ARRAY (p_value).lines LOOP
    v_fx_id:=CASE
      WHEN (v_line).source_currency=(v_period).currency THEN NULL
      ELSE v_resolved_fx_ids[(v_line).fx_source_ordinal] END;
    v_id:=gen_random_uuid();
    v_json:=to_jsonb(v_line)-ARRAY['fx_source_ordinal']||jsonb_build_object(
      'id',v_id,'row_kind','LINE',
      'period_revision_id',(v_period).period_revision_id,
      'period_revision_row_kind','PERIOD','supersedes_period_revision_id',NULL,
      'supersedes_period_row_kind',NULL,
      'deployment_id',(v_period).deployment_id,
      'accounting_timezone',(v_period).accounting_timezone,
      'accounting_policy_digest',btrim((v_period).accounting_policy_digest),
      'period_start',(v_period).period_start,'period_end',(v_period).period_end,
      'currency',btrim((v_period).currency),'period_version',(v_period).period_version,
      'fx_rate_fact_id',v_fx_id,'record_class','COMMERCIAL_ACCOUNTING_FACT',
      'recorded_at',v_now
    );
    v_cost_row:=jsonb_populate_record(NULL::ops.cost_allocations,v_json);
    v_digest:=ops.economics_import_row_digest_v1(
      'cost-allocation-line.v1',to_jsonb(v_cost_row),
      ARRAY['record_digest','recorded_at']
    );
    v_cost_row:=jsonb_populate_record(
      v_cost_row,jsonb_build_object('record_digest',btrim(v_digest))
    );
    v_result:=ops.insert_cost_allocation_v1(v_cost_row);
    v_results:=array_append(v_results,v_result);
  END LOOP;
  RETURN (v_results,v_primary,NULL)::ops.economics_import_effect_v1;
END
$$;
ALTER FUNCTION ops.apply_economics_cost_close_v1(
  ops.economics_cost_close_import_v1,ops.economics_import_governance_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_cost_close_v1(
  ops.economics_cost_close_import_v1,ops.economics_import_governance_v1
) FROM PUBLIC;

CREATE FUNCTION ops.economics_import_detail_contains_evidence_v1(
  p_ids uuid[],
  p_digests char(64)[],
  p_id uuid,
  p_digest char(64)
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,raw,pg_temp
AS $$
  SELECT COALESCE(
    p_id IS NOT NULL AND p_digest~'^[0-9a-f]{64}$'
    AND EXISTS (
      SELECT 1
      FROM unnest(p_ids) WITH ORDINALITY AS identity(id,ordinality)
      JOIN unnest(p_digests) WITH ORDINALITY AS digest(value,ordinality)
        USING (ordinality)
      JOIN raw.evidence_segments AS evidence
        ON evidence.id=identity.id AND evidence.segment_digest=digest.value
      WHERE identity.id=p_id AND digest.value=p_digest
    ),false
  )
$$;
ALTER FUNCTION ops.economics_import_detail_contains_evidence_v1(
  uuid[],char(64)[],uuid,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_import_detail_contains_evidence_v1(
  uuid[],char(64)[],uuid,char(64)
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_collection_failure_v1(
  p_value ops.economics_collection_failure_import_v1,
  p_execution_id uuid,
  p_generation bigint,
  p_action_detail_digest char(64)
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator'
     OR p_value IS NULL OR p_execution_id IS NULL OR p_generation<1
     OR p_action_detail_digest!~'^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'ECONOMICS_COLLECTION_FAILURE_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  -- A PAYMENT_REVIEW task and its notification intent must be atomic.  The
  -- active communication contract has no task-specific endpoint/topic and
  -- forbids PURPOSE_WIDE authorization, so no task identity or deployment can
  -- be invented.  Preserve the signed evidence in the approved detail and
  -- reject before the first task, intent, audit, outbox, economics, contract,
  -- entitlement, or public-access write.
  RAISE EXCEPTION 'REVIEW_AUTHORIZATION_NOT_CURRENT'
    USING ERRCODE='55000';
END
$$;
ALTER FUNCTION ops.apply_economics_collection_failure_v1(
  ops.economics_collection_failure_import_v1,uuid,bigint,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_collection_failure_v1(
  ops.economics_collection_failure_import_v1,uuid,bigint,char(64)
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_tariff_v1(
  p_value ops.economics_tariff_import_v1,
  p_governance ops.economics_import_governance_v1
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'ECO_APPLY_AUTHORITY_UNAVAILABLE: ECO-PER-DIGEST-REGISTRY'
    USING ERRCODE = '55000';
END
$$;
ALTER FUNCTION ops.apply_economics_tariff_v1(
  ops.economics_tariff_import_v1,ops.economics_import_governance_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_tariff_v1(
  ops.economics_tariff_import_v1,ops.economics_import_governance_v1
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_contract_v1(
  p_value ops.economics_contract_import_v1,
  p_governance ops.economics_import_governance_v1
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'ECO_APPLY_AUTHORITY_UNAVAILABLE: ECO-PER-DIGEST-REGISTRY'
    USING ERRCODE = '55000';
END
$$;
ALTER FUNCTION ops.apply_economics_contract_v1(
  ops.economics_contract_import_v1,ops.economics_import_governance_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_contract_v1(
  ops.economics_contract_import_v1,ops.economics_import_governance_v1
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_usage_window_v1(
  p_value ops.economics_usage_window_import_v1
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'ECO_APPLY_AUTHORITY_UNAVAILABLE: ECO-PER-DIGEST-REGISTRY'
    USING ERRCODE = '55000';
END
$$;
ALTER FUNCTION ops.apply_economics_usage_window_v1(
  ops.economics_usage_window_import_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_usage_window_v1(
  ops.economics_usage_window_import_v1
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_invoice_v1(
  p_value ops.economics_invoice_import_v1,
  p_governance ops.economics_import_governance_v1
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'ECO_APPLY_AUTHORITY_UNAVAILABLE: ECO-PER-DIGEST-REGISTRY'
    USING ERRCODE = '55000';
END
$$;
ALTER FUNCTION ops.apply_economics_invoice_v1(
  ops.economics_invoice_import_v1,ops.economics_import_governance_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_invoice_v1(
  ops.economics_invoice_import_v1,ops.economics_import_governance_v1
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_revenue_v1(
  p_value ops.economics_revenue_import_v1
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'ECO_APPLY_AUTHORITY_UNAVAILABLE: ECO-PER-DIGEST-REGISTRY'
    USING ERRCODE = '55000';
END
$$;
ALTER FUNCTION ops.apply_economics_revenue_v1(
  ops.economics_revenue_import_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_revenue_v1(
  ops.economics_revenue_import_v1
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_accounting_corrections_v1(
  p_value ops.economics_accounting_corrections_import_v1,
  p_governance ops.economics_import_governance_v1
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'ECO_APPLY_AUTHORITY_UNAVAILABLE: ECO-PER-DIGEST-REGISTRY'
    USING ERRCODE = '55000';
END
$$;
ALTER FUNCTION ops.apply_economics_accounting_corrections_v1(
  ops.economics_accounting_corrections_import_v1,
  ops.economics_import_governance_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_accounting_corrections_v1(
  ops.economics_accounting_corrections_import_v1,
  ops.economics_import_governance_v1
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_cash_applications_v1(
  p_value ops.economics_cash_applications_import_v1
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'ECO_APPLY_AUTHORITY_UNAVAILABLE: ECO-PER-DIGEST-REGISTRY'
    USING ERRCODE = '55000';
END
$$;
ALTER FUNCTION ops.apply_economics_cash_applications_v1(
  ops.economics_cash_applications_import_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_cash_applications_v1(
  ops.economics_cash_applications_import_v1
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_tax_invoices_v1(
  p_value ops.economics_tax_invoices_import_v1
) RETURNS ops.economics_import_effect_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RAISE EXCEPTION
    'ECO_APPLY_AUTHORITY_UNAVAILABLE: ECO-PER-DIGEST-REGISTRY'
    USING ERRCODE = '55000';
END
$$;
ALTER FUNCTION ops.apply_economics_tax_invoices_v1(
  ops.economics_tax_invoices_import_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_tax_invoices_v1(
  ops.economics_tax_invoices_import_v1
) FROM PUBLIC;

CREATE FUNCTION ops.apply_economics_import_operation_v1(
  p_operation ops.economics_import_operation_v1,
  p_execution_id uuid,
  p_generation bigint,
  p_approval_digest char(64)
) RETURNS ops.economics_import_apply_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,raw,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_auth ops.execution_authorizations%ROWTYPE;
  v_detail ops.action_approval_economics_import_details%ROWTYPE;
  v_governance ops.economics_import_governance_v1;
  v_effect ops.economics_import_effect_v1;
  v_requires_oversight boolean:=false;
  v_source ops.economics_acquisition_source_import_v1;
  v_fx_source ops.economics_fx_rate_source_import_v1;
  v_discount_source ops.economics_discount_source_import_v1;
  v_collection ops.economics_collection_failure_import_v1;
  v_audit_id uuid;
  v_audit_digest char(64);
  v_audit_result ops.economics_import_result_row_v1;
  v_results ops.economics_import_result_row_v1[];
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR current_user<>'gurine_migrator'
     OR p_operation IS NULL
     OR NOT ops.economics_import_operation_v1_is_valid(p_operation)
     OR p_execution_id IS NULL OR p_generation<1
     OR p_approval_digest!~'^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'ECONOMICS_IMPORT_APPLY_BINDING_INVALID'
      USING ERRCODE='P6E10';
  END IF;
  SELECT * INTO v_auth FROM ops.execution_authorizations
  WHERE execution_id=p_execution_id AND generation=p_generation
  FOR SHARE;
  IF NOT FOUND OR v_auth.action_kind<>'ECONOMICS_IMPORT'
     OR v_auth.approval_digest<>p_approval_digest
     OR v_auth.authorization_kind<>'INITIAL_APPROVAL'
     OR v_auth.executor_id<>'private.ExecuteEconomicsImport'
     OR v_auth.transport<>'PRIVATE_APPLICATION_COMMAND'
     OR v_auth.required_capability<>'economics.import'
     OR v_auth.target_request_schema_version<>'action-payload.v1'
     OR v_auth.effect_boundary<>'DATABASE_ONLY'
     OR v_auth.cost_class<>'NO_PAID_EGRESS'
     OR v_auth.provider_config_id IS NOT NULL
     OR v_auth.budget_reservation_id IS NOT NULL THEN
    RAISE EXCEPTION 'ECONOMICS_IMPORT_AUTHORIZATION_INVALID'
      USING ERRCODE='P6E10';
  END IF;
  SELECT * INTO v_detail
  FROM ops.action_approval_economics_import_details
  WHERE proposal_id=v_auth.proposal_id
    AND proposal_version=v_auth.proposal_version
  FOR SHARE;
  IF NOT FOUND OR v_detail.detail_kind<>'ECONOMICS_IMPORT'
     OR v_detail.approval_digest<>p_approval_digest
     OR v_detail.operation_id<>(p_operation).import_kind
     OR to_jsonb(v_detail.operation_value)<>to_jsonb(p_operation)
     OR v_detail.operation_canonical<>ops.canonical_jsonb_v1(to_jsonb(p_operation))
     OR v_detail.operation_digest<>encode(
       extensions.digest(v_detail.operation_canonical,'sha256'),'hex'
     )
     OR v_detail.content_digest<>v_auth.target_request_sha256 THEN
    RAISE EXCEPTION 'ECONOMICS_IMPORT_DETAIL_INVALID'
      USING ERRCODE='P6E10';
  END IF;

  -- Nested authorities must be a member of the exact rationale pair set.  A
  -- valid-looking source row outside that set cannot be smuggled into the
  -- approved operation.
  CASE (p_operation).import_kind
    WHEN 'recordCommercialQualification' THEN
      v_source:=((p_operation).record_commercial_qualification)
        .acquisition_source;
      IF NOT ops.economics_import_detail_contains_evidence_v1(
        v_detail.source_evidence_segment_ids,
        v_detail.source_evidence_digests,(v_source).evidence_segment_id,
        (v_source).evidence_segment_digest
      ) THEN
        RAISE EXCEPTION 'ECONOMICS_IMPORT_NESTED_EVIDENCE_INVALID'
          USING ERRCODE='P6E10';
      END IF;
    WHEN 'importCostAllocationClose' THEN
      FOREACH v_fx_source IN ARRAY
        ((p_operation).import_cost_allocation_close).fx_rates
      LOOP
        IF NOT ops.economics_import_detail_contains_evidence_v1(
          v_detail.source_evidence_segment_ids,
          v_detail.source_evidence_digests,
          (v_fx_source).evidence_segment_id,
          (v_fx_source).evidence_segment_digest
        ) THEN
          RAISE EXCEPTION 'ECONOMICS_IMPORT_NESTED_EVIDENCE_INVALID'
            USING ERRCODE='P6E10';
        END IF;
      END LOOP;
    WHEN 'recordInvoice' THEN
      FOREACH v_discount_source IN ARRAY
        ((p_operation).record_invoice).discounts
      LOOP
        IF NOT ops.economics_import_detail_contains_evidence_v1(
          v_detail.source_evidence_segment_ids,
          v_detail.source_evidence_digests,
          (v_discount_source).evidence_segment_id,
          (v_discount_source).evidence_segment_digest
        ) THEN
          RAISE EXCEPTION 'ECONOMICS_IMPORT_NESTED_EVIDENCE_INVALID'
            USING ERRCODE='P6E10';
        END IF;
      END LOOP;
    WHEN 'recordCollectionFailure' THEN
      v_collection:=(p_operation).record_collection_failure;
      IF (v_collection).authority_kind='BANK_RETURN_CONFIRMED'
         AND NOT ops.economics_import_detail_contains_evidence_v1(
           v_detail.source_evidence_segment_ids,
           v_detail.source_evidence_digests,
           (v_collection).signed_evidence_segment_id,
           (v_collection).signed_evidence_segment_digest
         ) THEN
        RAISE EXCEPTION 'ECONOMICS_IMPORT_NESTED_EVIDENCE_INVALID'
          USING ERRCODE='P6E10';
      END IF;
    ELSE NULL;
  END CASE;

  v_governance:=ops.economics_import_governance_v1(
    p_execution_id,p_generation,p_approval_digest
  );
  v_requires_oversight:=CASE (p_operation).import_kind
    WHEN 'createTariffVersion' THEN
      ((p_operation).create_tariff_version)
        .expected_projected_p75_variable_gross_margin_basis_points
      <((p_operation).create_tariff_version)
        .expected_required_variable_gross_margin_basis_points
    WHEN 'recordInvoice' THEN EXISTS (
      SELECT 1 FROM unnest(((p_operation).record_invoice).discounts) source
      WHERE (source).resolution='APPEND'
        AND ((source).append_value)
          .projected_margin_after_discount_basis_points
        <((source).append_value)
          .required_variable_gross_margin_basis_points
    )
    ELSE false
  END;
  IF (v_governance).proposer_id IS NULL
     OR (v_governance).approver_id IS NULL
     OR (v_governance).decision_digest!~'^[0-9a-f]{64}$'
     OR (v_governance).proposer_id=(v_governance).approver_id
     OR (v_governance).action_detail_digest<>v_detail.action_detail_digest
     OR (v_requires_oversight AND (
       (v_governance).counted_decision_count<>2
       OR (v_governance).oversight_approver_id IS NULL
       OR (v_governance).oversight_decision_digest!~'^[0-9a-f]{64}$'
       OR (v_governance).oversight_approver_id=ANY(ARRAY[
         (v_governance).proposer_id,(v_governance).approver_id
       ])
     )) OR (NOT v_requires_oversight AND (
       (v_governance).counted_decision_count<>1
       OR (v_governance).oversight_approver_id IS NOT NULL
       OR (v_governance).oversight_decision_digest IS NOT NULL
     )) THEN
    RAISE EXCEPTION 'ECONOMICS_IMPORT_QUORUM_INVALID'
      USING ERRCODE='P6E10';
  END IF;

  CASE (p_operation).import_kind
    WHEN 'recordCommercialQualification' THEN
      v_effect:=ops.apply_economics_qualification_v1(
        (p_operation).record_commercial_qualification,p_execution_id
      );
    WHEN 'importCostAllocationClose' THEN
      v_effect:=ops.apply_economics_cost_close_v1(
        (p_operation).import_cost_allocation_close,v_governance
      );
    WHEN 'createTariffVersion' THEN
      v_effect:=ops.apply_economics_tariff_v1(
        (p_operation).create_tariff_version,v_governance
      );
    WHEN 'recordCommercialContractPeriod' THEN
      v_effect:=ops.apply_economics_contract_v1(
        (p_operation).record_commercial_contract_period,v_governance
      );
    WHEN 'recordUsageWindow' THEN
      v_effect:=ops.apply_economics_usage_window_v1(
        (p_operation).record_usage_window
      );
    WHEN 'recordInvoice' THEN
      v_effect:=ops.apply_economics_invoice_v1(
        (p_operation).record_invoice,v_governance
      );
    WHEN 'recordRevenue' THEN
      v_effect:=ops.apply_economics_revenue_v1(
        (p_operation).record_revenue
      );
    WHEN 'recordAccountingCorrection' THEN
      v_effect:=ops.apply_economics_accounting_corrections_v1(
        (p_operation).record_accounting_correction,v_governance
      );
    WHEN 'recordCashApplication' THEN
      v_effect:=ops.apply_economics_cash_applications_v1(
        (p_operation).record_cash_application
      );
    WHEN 'recordTaxInvoiceIssuance' THEN
      v_effect:=ops.apply_economics_tax_invoices_v1(
        (p_operation).record_tax_invoice_issuance
      );
    WHEN 'recordCollectionFailure' THEN
      v_effect:=ops.apply_economics_collection_failure_v1(
        (p_operation).record_collection_failure,p_execution_id,p_generation,
        v_detail.action_detail_digest
      );
    ELSE
      RAISE EXCEPTION 'ECONOMICS_IMPORT_OPERATION_KIND_INVALID'
        USING ERRCODE='P6E10';
  END CASE;
  IF v_effect IS NULL OR cardinality((v_effect).result_rows)=0
     OR (v_effect).primary_result IS NULL THEN
    RAISE EXCEPTION 'ECONOMICS_IMPORT_EFFECT_INVALID'
      USING ERRCODE='P6E10';
  END IF;
  v_audit_id:=ops.append_audit_event(
    'economics-import:'||p_execution_id::text,'SERVICE',
    'workflow-worker.economics-import-executor',NULL::uuid,
    'ECONOMICS_IMPORT_APPLIED','EconomicsImportExecution',
    p_execution_id::text,'economics.import','SUCCESS',NULL,
    v_auth.request_id,jsonb_build_object(
      'executionId',p_execution_id,'generation',p_generation,
      'approvalDigest',btrim(p_approval_digest),
      'actionDetailDigest',btrim(v_detail.action_detail_digest),
      'operationId',(p_operation).import_kind,
      'operationDigest',btrim(v_detail.operation_digest)
    )
  );
  SELECT event.event_hash INTO STRICT v_audit_digest
  FROM ops.audit_events AS event WHERE event.id=v_audit_id;
  v_audit_result:=(
    'ECONOMICS_IMPORT_AUDIT_EVENT',v_audit_id,NULL,v_audit_digest
  )::ops.economics_import_result_row_v1;
  v_results:=array_append((v_effect).result_rows,v_audit_result);
  RETURN ops.finalize_economics_import_apply_v1(
    (p_operation).import_kind,v_results,(v_effect).primary_result,
    (v_effect).notification_outbox_event_id,v_now
  );
END
$$;
ALTER FUNCTION ops.apply_economics_import_operation_v1(
  ops.economics_import_operation_v1,uuid,bigint,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_economics_import_operation_v1(
  ops.economics_import_operation_v1,uuid,bigint,char(64)
) FROM PUBLIC;

-- 0028 froze these paid-review candidate keys, but the active physical
-- baseline never installed them.  R6e adds only the four columns consumed by
-- the paid-packet owner.  Existing snapshots remain nullable legacy rows;
-- no manifest or digest is inferred or backfilled.
ALTER TABLE editorial.review_snapshots
  ADD COLUMN member_set_digest char(64),
  ADD COLUMN paid_evidence_member_manifest jsonb,
  ADD COLUMN paid_evidence_member_manifest_canonical bytea,
  ADD COLUMN paid_evidence_member_manifest_digest char(64)
    GENERATED ALWAYS AS (
      encode(extensions.digest(
        paid_evidence_member_manifest_canonical,'sha256'
      ),'hex')
    ) STORED;
ALTER TABLE editorial.review_snapshots
  ADD CONSTRAINT review_snapshots_r6e_member_set_digest_ck CHECK (
    member_set_digest IS NULL OR member_set_digest ~ '^[0-9a-f]{64}$'
  ),
  ADD CONSTRAINT review_snapshots_r6e_paid_manifest_shape_ck CHECK (
    num_nonnulls(
      paid_evidence_member_manifest,
      paid_evidence_member_manifest_canonical,
      paid_evidence_member_manifest_digest
    ) IN (0,3)
    AND (
      paid_evidence_member_manifest_canonical IS NULL
      OR convert_from(
        paid_evidence_member_manifest_canonical,'UTF8'
      )::jsonb=paid_evidence_member_manifest
    )
    AND (
      paid_evidence_member_manifest_digest IS NULL
      OR paid_evidence_member_manifest_digest ~ '^[0-9a-f]{64}$'
    )
  ),
  ADD CONSTRAINT review_snapshots_r6e_member_binding_uq UNIQUE (
    id,case_id,case_version,snapshot_sha256,member_set_digest
  ),
  ADD CONSTRAINT review_snapshots_r6e_paid_manifest_binding_uq UNIQUE (
    id,case_id,case_version,snapshot_sha256,
    paid_evidence_member_manifest_digest
  );

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM ops.paid_evidence_packets AS packet
    LEFT JOIN editorial.review_snapshots AS snapshot
      ON snapshot.id=packet.review_snapshot_id
     AND snapshot.case_id=packet.review_case_id
     AND snapshot.case_version=packet.review_snapshot_version
     AND snapshot.snapshot_sha256=packet.review_snapshot_digest
     AND snapshot.paid_evidence_member_manifest_digest=
         packet.paid_member_manifest_digest
    WHERE snapshot.id IS NULL
  ) THEN
    RAISE EXCEPTION 'PAID_PACKET_REVIEW_SNAPSHOT_BINDING_INVALID'
      USING ERRCODE='23503';
  END IF;
END
$$;
ALTER TABLE ops.paid_evidence_packets
  ADD CONSTRAINT paid_packet_review_snapshot_fk FOREIGN KEY (
    review_snapshot_id,review_case_id,review_snapshot_version,
    review_snapshot_digest,paid_member_manifest_digest
  ) REFERENCES editorial.review_snapshots(
    id,case_id,case_version,snapshot_sha256,
    paid_evidence_member_manifest_digest
  ) ON DELETE RESTRICT NOT VALID;
ALTER TABLE ops.paid_evidence_packets
  VALIDATE CONSTRAINT paid_packet_review_snapshot_fk;

CREATE FUNCTION ops.materialize_paid_evidence_packet_subject_v1(
  p_subject ops.paid_evidence_packet_subject_input_v1,
  p_idempotency_key text
) RETURNS ops.economics_mutation_receipt_v1
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,core,raw,intake,extensions,pg_temp
SET timezone='UTC'
AS $r6e_paid_materialize$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_request_id uuid := gen_random_uuid();
  v_key_hash char(64);
  v_request_hash char(64);
  v_existing_key ops.idempotency_keys%ROWTYPE;
  v_existing_packet ops.paid_evidence_packets%ROWTYPE;
  v_source_event ops.outbox%ROWTYPE;
  v_qualification ops.commercial_qualification_receipts%ROWTYPE;
  v_contract ops.commercial_contract_periods%ROWTYPE;
  v_snapshot editorial.review_snapshots%ROWTYPE;
  v_member ops.paid_evidence_packet_member_input_v1;
  v_member_ordinal integer := 0;
  v_expected_categories constant text[] := ARRAY[
    'AUTHORIZED_DATASET_SNAPSHOT',
    'SOURCE_RIGHTS',
    'CAPABILITY_ACTIVATION',
    'EXTRACTION_AND_TRANSFORMATION_LINEAGE',
    'REPRODUCTION_AND_COMPARISON_INPUT',
    'SUPPORTING_CONTRARY_AND_LOCATOR_EVIDENCE',
    'FRESHNESS_LIMITATION_DISAGREEMENT_AND_UNKNOWN_DISCLOSURE',
    'AI_PROVENANCE_WHEN_CONTRIBUTED',
    'HUMAN_DECISION',
    'INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED'
  ];
  v_manifest_category jsonb;
  v_nested_disposition jsonb;
  v_payload_valid boolean;
  v_source_set_id uuid;
  v_source_set_version bigint;
  v_source_set_digest char(64);
  v_member_preimage jsonb;
  v_member_preimage_canonical bytea;
  v_member_record_digest char(64);
  v_member_bindings jsonb := '[]'::jsonb;
  v_member_record_members jsonb := '[]'::jsonb;
  v_member_set_digest char(64);
  v_subject_kind ops.paid_evidence_subject_kind;
  v_subject_delivery_id uuid;
  v_subject_rendering_digest char(64);
  v_subject_authorization_snapshot_digest char(64);
  v_decision_cycle_id uuid;
  v_decision_cycle_version bigint;
  v_decision_cycle_digest char(64);
  v_subject_payload jsonb;
  v_subject_canonical bytea;
  v_packet_subject_digest char(64);
  v_packet_record_preimage jsonb;
  v_packet_record_payload jsonb;
  v_packet_record_preimage_canonical bytea;
  v_packet_record_canonical bytea;
  v_packet_record_digest char(64);
  v_audit_id uuid;
  v_outbox_id uuid := gen_random_uuid();
  v_operation_receipt_digest char(64);
  v_event_payload jsonb;
  v_response jsonb;
  v_response_bytes bytea;
  v_response_digest char(64);
BEGIN
  -- The authority currently requires packetMemberSetDigest inside every
  -- member-record preimage while also ordering every member-record digest
  -- before memberSetDigest.  Activating either interpretation would invent a
  -- digest contract, so this draft remains statically unavailable pre-write.
  RAISE EXCEPTION 'PAID_PACKET_DIGEST_AUTHORITY_UNAVAILABLE'
    USING ERRCODE='55000';
  IF session_user IS DISTINCT FROM 'gurine_workflow_worker'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'PAID_PACKET_CALLER_FORBIDDEN' USING ERRCODE='42501';
  END IF;
  IF current_setting('transaction_isolation')<>'serializable' THEN
    RAISE EXCEPTION 'PAID_PACKET_SERIALIZABLE_REQUIRED' USING ERRCODE='25001';
  END IF;
  IF p_subject IS NULL OR p_idempotency_key IS NULL
     OR length(btrim(p_idempotency_key)) NOT BETWEEN 1 AND 200
     OR (p_subject).source_event_id IS NULL
     OR (p_subject).source_event_envelope_digest !~ '^[0-9a-f]{64}$'
     OR (p_subject).packet_id IS NULL
     OR (p_subject).deployment_id IS NULL
     OR (p_subject).organization_id IS NULL
     OR (p_subject).sku IS DISTINCT FROM
        'EVIDENCE_WORKSPACE_ORGANIZATION_V1'::ops.commercial_sku
     OR (p_subject).qualification_receipt_id IS NULL
     OR (p_subject).qualification_episode_id IS NULL
     OR (p_subject).qualification_episode_version IS NULL
     OR (p_subject).qualification_episode_version<=0
     OR (p_subject).qualification_episode_digest !~ '^[0-9a-f]{64}$'
     OR (p_subject).commercial_contract_id IS NULL
     OR (p_subject).commercial_contract_version IS NULL
     OR (p_subject).commercial_contract_version<=0
     OR (p_subject).commercial_contract_digest !~ '^[0-9a-f]{64}$'
     OR (p_subject).review_snapshot_id IS NULL
     OR (p_subject).review_snapshot_version IS NULL
     OR (p_subject).review_snapshot_version<=0
     OR (p_subject).review_snapshot_digest !~ '^[0-9a-f]{64}$'
     OR (p_subject).paid_member_manifest_digest !~ '^[0-9a-f]{64}$'
     OR (p_subject).expected_packet_subject_digest !~ '^[0-9a-f]{64}$'
     OR (p_subject).subject_binding_payload IS NULL
     OR (p_subject).subject_binding_canonical IS NULL
     OR cardinality((p_subject).ordered_members)<>10
  THEN
    RAISE EXCEPTION 'PAID_EVIDENCE_SUBJECT_INVALID' USING ERRCODE='22023';
  END IF;

  v_key_hash := encode(extensions.digest(
    convert_to(btrim(p_idempotency_key),'UTF8'),'sha256'
  ),'hex');
  v_request_hash := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_MATERIALIZE_PAID_EVIDENCE_PACKET_REQUEST_V1',
      'schemaVersion',1,'subject',to_jsonb(p_subject)
    )
  ),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'ECONOMICS.MATERIALIZE_PAID_EVIDENCE_PACKET_SUBJECT.V1:'||v_key_hash,0
  ));
  SELECT * INTO v_existing_key
  FROM ops.idempotency_keys
  WHERE scope='ECONOMICS.MATERIALIZE_PAID_EVIDENCE_PACKET_SUBJECT.V1'
    AND key_hash=v_key_hash
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing_key.request_hash IS DISTINCT FROM v_request_hash
       OR v_existing_key.response_status IS DISTINCT FROM 201
       OR v_existing_key.response_body IS NULL THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='22023';
    END IF;
    v_response := v_existing_key.response_body;
    v_response_bytes := ops.canonical_jsonb_v1(v_response);
    v_response_digest := encode(
      extensions.digest(v_response_bytes,'sha256'),'hex'
    );
    RETURN (
      (v_response->>'receiptId')::uuid,
      'PAID_EVIDENCE_PACKET_SUBJECT',(v_response->>'packetId')::uuid,
      (v_response->>'packetVersion')::bigint,
      (v_response->>'packetRecordDigest')::char(64),
      (v_response->>'auditEventId')::uuid,
      (v_response->>'outboxId')::uuid,201,'application/json',
      v_response_bytes,v_response_digest,
      (v_response->>'receiptDigest')::char(64),
      (v_response->>'occurredAt')::timestamptz,true
    )::ops.economics_mutation_receipt_v1;
  END IF;
  INSERT INTO ops.idempotency_keys(
    scope,key_hash,request_hash,resource_type,resource_id,expires_at
  ) VALUES (
    'ECONOMICS.MATERIALIZE_PAID_EVIDENCE_PACKET_SUBJECT.V1',
    v_key_hash,v_request_hash,'PAID_EVIDENCE_PACKET_SUBJECT',
    (p_subject).packet_id::text,v_now+interval '30 days'
  );

  SELECT * INTO v_source_event FROM ops.outbox
  WHERE id=(p_subject).source_event_id FOR SHARE;
  IF NOT FOUND OR ops.r6d_outbox_envelope_digest_v1(v_source_event.id)
      IS DISTINCT FROM (p_subject).source_event_envelope_digest THEN
    RAISE EXCEPTION 'EVENT_REPLAY_CONFLICT' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_qualification
  FROM ops.commercial_qualification_receipts AS qualification
  WHERE qualification.id=(p_subject).qualification_receipt_id
    AND qualification.deployment_id=(p_subject).deployment_id
    AND qualification.organization_id=(p_subject).organization_id
    AND qualification.sku=(p_subject).sku
    AND qualification.qualification_episode_id=
        (p_subject).qualification_episode_id
    AND qualification.revision=(p_subject).qualification_episode_version
    AND qualification.receipt_digest=(p_subject).qualification_episode_digest
  FOR SHARE;
  IF NOT FOUND OR v_qualification.receipt_effect='REVERSAL'
     OR EXISTS (
       SELECT 1 FROM ops.commercial_qualification_receipts AS successor
       WHERE successor.root_receipt_id=v_qualification.root_receipt_id
         AND successor.revision>v_qualification.revision
     ) THEN
    RAISE EXCEPTION 'PAID_EVIDENCE_SUBJECT_INVALID' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_contract
  FROM ops.commercial_contract_periods AS contract
  WHERE contract.id=(p_subject).commercial_contract_id
    AND contract.deployment_id=(p_subject).deployment_id
    AND contract.organization_id=(p_subject).organization_id
    AND contract.sku=(p_subject).sku
    AND contract.revision=(p_subject).commercial_contract_version
    AND contract.record_digest=(p_subject).commercial_contract_digest
    AND contract.qualification_receipt_id=v_qualification.id
    AND contract.qualification_episode_id=v_qualification.qualification_episode_id
    AND contract.qualification_receipt_digest=v_qualification.receipt_digest
  FOR SHARE;
  IF NOT FOUND OR v_contract.fact_effect='REVERSAL'
     OR v_contract.status<>'ACTIVE'
     OR v_contract.provisioning_state<>'PROVISIONED'
     OR v_contract.state_effective_at>v_now
     OR v_contract.period_start>(v_now AT TIME ZONE
         v_contract.accounting_timezone)::date
     OR v_contract.period_end<=(v_now AT TIME ZONE
         v_contract.accounting_timezone)::date
     OR EXISTS (
       SELECT 1 FROM ops.commercial_contract_periods AS successor
       WHERE successor.supersedes_contract_period_id=v_contract.id
     ) THEN
    RAISE EXCEPTION 'PAID_EVIDENCE_SUBJECT_INVALID' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_snapshot
  FROM editorial.review_snapshots AS snapshot
  WHERE snapshot.id=(p_subject).review_snapshot_id
    AND snapshot.case_version=(p_subject).review_snapshot_version
    AND snapshot.snapshot_sha256=(p_subject).review_snapshot_digest
    AND snapshot.paid_evidence_member_manifest_digest=
        (p_subject).paid_member_manifest_digest
  FOR SHARE;
  IF NOT FOUND OR v_snapshot.member_set_digest IS NULL
     OR v_snapshot.paid_evidence_member_manifest IS NULL
     OR v_snapshot.paid_evidence_member_manifest_canonical IS NULL
     OR jsonb_typeof(v_snapshot.paid_evidence_member_manifest)<>'object'
     OR NOT (v_snapshot.paid_evidence_member_manifest ?& ARRAY[
       'schemaVersion','reviewSnapshotId','reviewSnapshotVersion',
       'reviewSnapshotDigest','categories','memberSetDigest'
     ])
     OR EXISTS (
       SELECT 1 FROM jsonb_object_keys(
         v_snapshot.paid_evidence_member_manifest
       ) AS key
       WHERE key NOT IN (
         'schemaVersion','reviewSnapshotId','reviewSnapshotVersion',
         'reviewSnapshotDigest','categories','memberSetDigest'
       )
     )
     OR v_snapshot.paid_evidence_member_manifest->>'schemaVersion'<>'1'
     OR (v_snapshot.paid_evidence_member_manifest->>'reviewSnapshotId')::uuid
        <>v_snapshot.id
     OR (v_snapshot.paid_evidence_member_manifest->>'reviewSnapshotVersion')::bigint
        <>v_snapshot.case_version
     OR v_snapshot.paid_evidence_member_manifest->>'reviewSnapshotDigest'
        <>btrim(v_snapshot.snapshot_sha256)
     OR jsonb_typeof(
       v_snapshot.paid_evidence_member_manifest->'categories'
     )<>'array'
     OR jsonb_array_length(
       v_snapshot.paid_evidence_member_manifest->'categories'
     )<>10
     OR v_snapshot.paid_evidence_member_manifest->>'memberSetDigest'
        !~ '^[0-9a-f]{64}$'
  THEN
    RAISE EXCEPTION 'PAID_EVIDENCE_MEMBER_SET_INVALID' USING ERRCODE='22023';
  END IF;

  FOREACH v_member IN ARRAY (p_subject).ordered_members LOOP
    IF v_member IS NULL OR v_member.member_ordinal<>v_member_ordinal
       OR v_member.category::text<>v_expected_categories[v_member_ordinal+1]
       OR v_member.source_set_id IS NULL
       OR v_member.source_set_version IS NULL
       OR v_member.source_set_version<=0
       OR v_member.source_set_digest !~ '^[0-9a-f]{64}$'
       OR v_member.member_payload IS NULL
       OR v_member.member_canonical IS NULL
       OR v_member.member_digest_preimage_canonical IS NULL
       OR jsonb_typeof(v_member.member_payload)<>'object'
       OR v_member.member_payload->>'category'<>v_member.category::text
       OR v_member.member_payload->>'ordinal'<>v_member_ordinal::text
       OR v_member.member_payload->>'memberSetDigest' !~ '^[0-9a-f]{64}$'
       OR ops.canonical_jsonb_v1(v_member.member_payload)
          IS DISTINCT FROM v_member.member_canonical
    THEN
      RAISE EXCEPTION 'PAID_EVIDENCE_MEMBER_SET_INVALID'
        USING ERRCODE='22023';
    END IF;

    v_nested_disposition := NULL;
    v_payload_valid := CASE v_member.category::text
      WHEN 'AUTHORIZED_DATASET_SNAPSHOT' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','datasetSnapshotId','datasetSnapshotVersion',
          'datasetSnapshotDigest','memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','datasetSnapshotId','datasetSnapshotVersion',
            'datasetSnapshotDigest','memberSetDigest'
          )
        )
      WHEN 'SOURCE_RIGHTS' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','rightsDecisionSetId',
          'rightsDecisionSetVersion','rightsDecisionSetDigest','memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','rightsDecisionSetId',
            'rightsDecisionSetVersion','rightsDecisionSetDigest','memberSetDigest'
          )
        )
      WHEN 'CAPABILITY_ACTIVATION' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','activationDecisionSetId',
          'activationDecisionSetVersion','activationDecisionSetDigest',
          'memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','activationDecisionSetId',
            'activationDecisionSetVersion','activationDecisionSetDigest',
            'memberSetDigest'
          )
        )
      WHEN 'EXTRACTION_AND_TRANSFORMATION_LINEAGE' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','lineageReceiptSetId',
          'lineageReceiptSetVersion','lineageReceiptSetDigest','memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','lineageReceiptSetId',
            'lineageReceiptSetVersion','lineageReceiptSetDigest','memberSetDigest'
          )
        )
      WHEN 'REPRODUCTION_AND_COMPARISON_INPUT' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','reproductionInputSetId',
          'reproductionInputSetVersion','reproductionInputSetDigest',
          'memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','reproductionInputSetId',
            'reproductionInputSetVersion','reproductionInputSetDigest',
            'memberSetDigest'
          )
        )
      WHEN 'SUPPORTING_CONTRARY_AND_LOCATOR_EVIDENCE' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','evidenceSetId','evidenceSetVersion',
          'evidenceSetDigest','memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','evidenceSetId','evidenceSetVersion',
            'evidenceSetDigest','memberSetDigest'
          )
        )
      WHEN 'FRESHNESS_LIMITATION_DISAGREEMENT_AND_UNKNOWN_DISCLOSURE' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','disclosureSetId','disclosureSetVersion',
          'disclosureSetDigest','memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','disclosureSetId','disclosureSetVersion',
            'disclosureSetDigest','memberSetDigest'
          )
        )
      WHEN 'AI_PROVENANCE_WHEN_CONTRIBUTED' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','provenanceDisposition','memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','provenanceDisposition','memberSetDigest'
          )
        ) AND jsonb_typeof(
          v_member.member_payload->'provenanceDisposition'
        )='object'
      WHEN 'HUMAN_DECISION' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','humanDecisionSetId',
          'humanDecisionSetVersion','humanDecisionSetDigest','memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','humanDecisionSetId',
            'humanDecisionSetVersion','humanDecisionSetDigest','memberSetDigest'
          )
        )
      WHEN 'INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED' THEN
        v_member.member_payload ?& ARRAY[
          'category','ordinal','reviewDisposition','memberSetDigest'
        ] AND NOT EXISTS (
          SELECT 1 FROM jsonb_object_keys(v_member.member_payload) AS key
          WHERE key NOT IN (
            'category','ordinal','reviewDisposition','memberSetDigest'
          )
        ) AND jsonb_typeof(
          v_member.member_payload->'reviewDisposition'
        )='object'
      ELSE false
    END;
    IF NOT v_payload_valid THEN
      RAISE EXCEPTION 'PAID_EVIDENCE_MEMBER_SET_INVALID'
        USING ERRCODE='22023';
    END IF;

    CASE v_member.category::text
      WHEN 'AUTHORIZED_DATASET_SNAPSHOT' THEN
        v_source_set_id :=
          (v_member.member_payload->>'datasetSnapshotId')::uuid;
        v_source_set_version :=
          (v_member.member_payload->>'datasetSnapshotVersion')::bigint;
        v_source_set_digest :=
          (v_member.member_payload->>'datasetSnapshotDigest')::char(64);
      WHEN 'SOURCE_RIGHTS' THEN
        v_source_set_id :=
          (v_member.member_payload->>'rightsDecisionSetId')::uuid;
        v_source_set_version :=
          (v_member.member_payload->>'rightsDecisionSetVersion')::bigint;
        v_source_set_digest :=
          (v_member.member_payload->>'rightsDecisionSetDigest')::char(64);
      WHEN 'CAPABILITY_ACTIVATION' THEN
        v_source_set_id :=
          (v_member.member_payload->>'activationDecisionSetId')::uuid;
        v_source_set_version :=
          (v_member.member_payload->>'activationDecisionSetVersion')::bigint;
        v_source_set_digest :=
          (v_member.member_payload->>'activationDecisionSetDigest')::char(64);
      WHEN 'EXTRACTION_AND_TRANSFORMATION_LINEAGE' THEN
        v_source_set_id :=
          (v_member.member_payload->>'lineageReceiptSetId')::uuid;
        v_source_set_version :=
          (v_member.member_payload->>'lineageReceiptSetVersion')::bigint;
        v_source_set_digest :=
          (v_member.member_payload->>'lineageReceiptSetDigest')::char(64);
      WHEN 'REPRODUCTION_AND_COMPARISON_INPUT' THEN
        v_source_set_id :=
          (v_member.member_payload->>'reproductionInputSetId')::uuid;
        v_source_set_version :=
          (v_member.member_payload->>'reproductionInputSetVersion')::bigint;
        v_source_set_digest :=
          (v_member.member_payload->>'reproductionInputSetDigest')::char(64);
      WHEN 'SUPPORTING_CONTRARY_AND_LOCATOR_EVIDENCE' THEN
        v_source_set_id :=
          (v_member.member_payload->>'evidenceSetId')::uuid;
        v_source_set_version :=
          (v_member.member_payload->>'evidenceSetVersion')::bigint;
        v_source_set_digest :=
          (v_member.member_payload->>'evidenceSetDigest')::char(64);
      WHEN 'FRESHNESS_LIMITATION_DISAGREEMENT_AND_UNKNOWN_DISCLOSURE' THEN
        v_source_set_id :=
          (v_member.member_payload->>'disclosureSetId')::uuid;
        v_source_set_version :=
          (v_member.member_payload->>'disclosureSetVersion')::bigint;
        v_source_set_digest :=
          (v_member.member_payload->>'disclosureSetDigest')::char(64);
      WHEN 'AI_PROVENANCE_WHEN_CONTRIBUTED' THEN
        v_nested_disposition :=
          v_member.member_payload->'provenanceDisposition';
        IF v_nested_disposition->>'kind'='CONTRIBUTED' THEN
          v_payload_valid := v_nested_disposition ?& ARRAY[
            'kind','agentOutputValidationSetId',
            'agentOutputValidationSetVersion','agentOutputValidationSetDigest'
          ] AND NOT EXISTS (
            SELECT 1 FROM jsonb_object_keys(v_nested_disposition) AS key
            WHERE key NOT IN (
              'kind','agentOutputValidationSetId',
              'agentOutputValidationSetVersion','agentOutputValidationSetDigest'
            )
          );
          v_source_set_id :=
            (v_nested_disposition->>'agentOutputValidationSetId')::uuid;
          v_source_set_version :=
            (v_nested_disposition->>'agentOutputValidationSetVersion')::bigint;
          v_source_set_digest :=
            (v_nested_disposition->>'agentOutputValidationSetDigest')::char(64);
        ELSIF v_nested_disposition->>'kind'='DID_NOT_CONTRIBUTE' THEN
          v_payload_valid := v_nested_disposition ?& ARRAY[
            'kind','reviewSnapshotId','reviewSnapshotVersion',
            'reviewSnapshotDigest','policyEvaluationDigest'
          ] AND NOT EXISTS (
            SELECT 1 FROM jsonb_object_keys(v_nested_disposition) AS key
            WHERE key NOT IN (
              'kind','reviewSnapshotId','reviewSnapshotVersion',
              'reviewSnapshotDigest','policyEvaluationDigest'
            )
          );
          v_source_set_id :=
            (v_nested_disposition->>'reviewSnapshotId')::uuid;
          v_source_set_version :=
            (v_nested_disposition->>'reviewSnapshotVersion')::bigint;
          v_source_set_digest :=
            (v_nested_disposition->>'reviewSnapshotDigest')::char(64);
        ELSE
          v_payload_valid := false;
        END IF;
      WHEN 'HUMAN_DECISION' THEN
        v_source_set_id :=
          (v_member.member_payload->>'humanDecisionSetId')::uuid;
        v_source_set_version :=
          (v_member.member_payload->>'humanDecisionSetVersion')::bigint;
        v_source_set_digest :=
          (v_member.member_payload->>'humanDecisionSetDigest')::char(64);
      WHEN 'INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED' THEN
        v_nested_disposition := v_member.member_payload->'reviewDisposition';
        IF v_nested_disposition->>'kind'='COMPLETED' THEN
          v_payload_valid := v_nested_disposition ?& ARRAY[
            'kind','reviewReceiptSetId','reviewReceiptSetVersion',
            'reviewReceiptSetDigest'
          ] AND NOT EXISTS (
            SELECT 1 FROM jsonb_object_keys(v_nested_disposition) AS key
            WHERE key NOT IN (
              'kind','reviewReceiptSetId','reviewReceiptSetVersion',
              'reviewReceiptSetDigest'
            )
          );
          v_source_set_id :=
            (v_nested_disposition->>'reviewReceiptSetId')::uuid;
          v_source_set_version :=
            (v_nested_disposition->>'reviewReceiptSetVersion')::bigint;
          v_source_set_digest :=
            (v_nested_disposition->>'reviewReceiptSetDigest')::char(64);
        ELSIF v_nested_disposition->>'kind'='POLICY_NOT_REQUIRED' THEN
          v_payload_valid := v_nested_disposition ?& ARRAY[
            'kind','reviewSnapshotId','reviewSnapshotVersion',
            'reviewSnapshotDigest','policyEvaluationDigest'
          ] AND NOT EXISTS (
            SELECT 1 FROM jsonb_object_keys(v_nested_disposition) AS key
            WHERE key NOT IN (
              'kind','reviewSnapshotId','reviewSnapshotVersion',
              'reviewSnapshotDigest','policyEvaluationDigest'
            )
          );
          v_source_set_id :=
            (v_nested_disposition->>'reviewSnapshotId')::uuid;
          v_source_set_version :=
            (v_nested_disposition->>'reviewSnapshotVersion')::bigint;
          v_source_set_digest :=
            (v_nested_disposition->>'reviewSnapshotDigest')::char(64);
        ELSE
          v_payload_valid := false;
        END IF;
    END CASE;

    v_manifest_category :=
      v_snapshot.paid_evidence_member_manifest->'categories'->v_member_ordinal;
    IF NOT v_payload_valid OR v_source_set_id IS DISTINCT FROM
         v_member.source_set_id
       OR v_source_set_version IS DISTINCT FROM v_member.source_set_version
       OR v_source_set_digest IS DISTINCT FROM v_member.source_set_digest
       OR v_source_set_digest !~ '^[0-9a-f]{64}$'
       OR v_source_set_version<=0
       OR jsonb_typeof(v_manifest_category)<>'object'
       OR v_manifest_category->>'ordinal'<>v_member_ordinal::text
       OR v_manifest_category->>'category'<>v_member.category::text
       OR v_manifest_category->>'disposition'
          IS DISTINCT FROM v_member.disposition_kind
       OR v_manifest_category->>'categoryDigest'
          IS DISTINCT FROM v_member.member_payload->>'memberSetDigest'
       OR (
         v_member.category::text NOT IN (
           'AI_PROVENANCE_WHEN_CONTRIBUTED',
           'INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED'
         ) AND v_member.disposition_kind IS NOT NULL
       )
       OR (
         v_member.category::text='AI_PROVENANCE_WHEN_CONTRIBUTED'
         AND v_member.disposition_kind IS DISTINCT FROM
             v_nested_disposition->>'kind'
       )
       OR (
         v_member.category::text=
           'INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED'
         AND v_member.disposition_kind IS DISTINCT FROM
             v_nested_disposition->>'kind'
       )
    THEN
      RAISE EXCEPTION 'PAID_EVIDENCE_MEMBER_SET_INVALID'
        USING ERRCODE='22023';
    END IF;

    v_member_preimage := jsonb_build_object(
      'schemaVersion',1,'packetId',(p_subject).packet_id,
      'packetVersion',1,'memberOrdinal',v_member.member_ordinal,
      'category',v_member.category,'sourceSetId',v_member.source_set_id,
      'sourceSetVersion',v_member.source_set_version,
      'sourceSetDigest',v_member.source_set_digest,
      'dispositionKind',v_member.disposition_kind,
      'memberPayload',v_member.member_payload
    );
    v_member_preimage_canonical := ops.canonical_jsonb_v1(v_member_preimage);
    IF v_member.member_digest_preimage_canonical IS DISTINCT FROM
       v_member_preimage_canonical THEN
      RAISE EXCEPTION 'PAID_EVIDENCE_MEMBER_SET_INVALID'
        USING ERRCODE='22023';
    END IF;
    v_member_record_digest := encode(
      extensions.digest(v_member_preimage_canonical,'sha256'),'hex'
    );
    v_member_record_members := v_member_record_members||jsonb_build_array(
      jsonb_build_object(
        'memberOrdinal',v_member.member_ordinal,
        'category',v_member.category,
        'sourceSetId',v_member.source_set_id,
        'sourceSetVersion',v_member.source_set_version,
        'sourceSetDigest',v_member.source_set_digest,
        'dispositionKind',v_member.disposition_kind,
        'memberRecordDigest',v_member_record_digest
      )
    );
    v_member_bindings := v_member_bindings||jsonb_build_array(
      jsonb_build_object(
        'memberOrdinal',v_member.member_ordinal,
        'category',v_member.category,
        'sourceSetId',v_member.source_set_id,
        'sourceSetVersion',v_member.source_set_version,
        'sourceSetDigest',v_member.source_set_digest,
        'dispositionKind',v_member.disposition_kind,
        'memberSetDigest',v_member.member_payload->>'memberSetDigest'
      )
    );
    v_member_ordinal := v_member_ordinal+1;
  END LOOP;

  IF v_member_ordinal<>10 THEN
    RAISE EXCEPTION 'PAID_EVIDENCE_MEMBER_SET_INVALID' USING ERRCODE='22023';
  END IF;
  v_member_set_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_PAID_EVIDENCE_PACKET_MEMBER_SET_V1',
      'schemaVersion',1,'members',v_member_record_members
    )
  ),'sha256'),'hex');

  BEGIN
    v_subject_kind :=
      ((p_subject).subject_binding_payload->>'subjectKind')::
        ops.paid_evidence_subject_kind;
    IF v_subject_kind='AUDITED_DELIVERY' THEN
      v_subject_delivery_id :=
        ((p_subject).subject_binding_payload->>'subjectDeliveryId')::uuid;
      v_subject_rendering_digest :=
        ((p_subject).subject_binding_payload->>'renderingDigest')::char(64);
      v_subject_authorization_snapshot_digest :=
        ((p_subject).subject_binding_payload->>
          'authorizationSnapshotDigest')::char(64);
      IF v_subject_rendering_digest !~ '^[0-9a-f]{64}$'
         OR v_subject_authorization_snapshot_digest !~ '^[0-9a-f]{64}$'
         OR NOT EXISTS (
           SELECT 1 FROM ops.outbound_deliveries AS delivery
           WHERE delivery.id=v_subject_delivery_id
             AND delivery.rendering_digest=v_subject_rendering_digest
             AND delivery.authorization_snapshot_digest=
                 v_subject_authorization_snapshot_digest
         ) THEN
        RAISE EXCEPTION 'PAID_EVIDENCE_SUBJECT_INVALID'
          USING ERRCODE='22023';
      END IF;
    ELSE
      v_decision_cycle_id :=
        ((p_subject).subject_binding_payload->>'decisionCycleId')::uuid;
      v_decision_cycle_version :=
        ((p_subject).subject_binding_payload->>'decisionCycleVersion')::bigint;
      v_decision_cycle_digest :=
        ((p_subject).subject_binding_payload->>'decisionCycleDigest')::char(64);
      IF v_decision_cycle_version<=0
         OR v_decision_cycle_digest !~ '^[0-9a-f]{64}$'
         OR NOT EXISTS (
           SELECT 1 FROM ops.action_proposal_versions AS proposal
           WHERE proposal.proposal_id=v_decision_cycle_id
             AND proposal.version=v_decision_cycle_version
             AND proposal.approval_digest=v_decision_cycle_digest
         ) THEN
        RAISE EXCEPTION 'PAID_EVIDENCE_SUBJECT_INVALID'
          USING ERRCODE='22023';
      END IF;
    END IF;
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'PAID_EVIDENCE_SUBJECT_INVALID'
        USING ERRCODE='22023';
  END;

  v_subject_payload := jsonb_build_object(
    'schemaVersion',1,'packetId',(p_subject).packet_id,
    'deploymentId',(p_subject).deployment_id,
    'organizationId',(p_subject).organization_id,'sku',(p_subject).sku,
    'qualificationReceiptId',(p_subject).qualification_receipt_id,
    'qualificationEpisodeId',(p_subject).qualification_episode_id,
    'qualificationEpisodeVersion',(p_subject).qualification_episode_version,
    'qualificationEpisodeDigest',(p_subject).qualification_episode_digest,
    'commercialContractId',(p_subject).commercial_contract_id,
    'commercialContractVersion',(p_subject).commercial_contract_version,
    'commercialContractDigest',(p_subject).commercial_contract_digest,
    'reviewSnapshotId',(p_subject).review_snapshot_id,
    'reviewSnapshotVersion',(p_subject).review_snapshot_version,
    'reviewSnapshotDigest',(p_subject).review_snapshot_digest,
    'paidMemberManifestDigest',(p_subject).paid_member_manifest_digest,
    'subjectKind',v_subject_kind,
    'subjectDeliveryId',v_subject_delivery_id,
    'renderingDigest',v_subject_rendering_digest,
    'authorizationSnapshotDigest',v_subject_authorization_snapshot_digest,
    'decisionCycleId',v_decision_cycle_id,
    'decisionCycleVersion',v_decision_cycle_version,
    'decisionCycleDigest',v_decision_cycle_digest,
    'orderedMemberBindings',v_member_bindings
  );
  v_subject_canonical := ops.canonical_jsonb_v1(v_subject_payload);
  v_packet_subject_digest := encode(
    extensions.digest(v_subject_canonical,'sha256'),'hex'
  );
  IF (p_subject).subject_binding_payload IS DISTINCT FROM v_subject_payload
     OR (p_subject).subject_binding_canonical IS DISTINCT FROM
        v_subject_canonical
     OR (p_subject).expected_packet_subject_digest IS DISTINCT FROM
        v_packet_subject_digest THEN
    RAISE EXCEPTION 'PAID_EVIDENCE_SUBJECT_INVALID' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_existing_packet
  FROM ops.paid_evidence_packets
  WHERE packet_id=(p_subject).packet_id
  ORDER BY packet_version DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    IF v_existing_packet.packet_version=1
       AND v_existing_packet.packet_subject_digest=v_packet_subject_digest
       AND v_existing_packet.source_event_id=(p_subject).source_event_id
       AND v_existing_packet.source_event_envelope_digest=
           (p_subject).source_event_envelope_digest THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='22023';
    END IF;
    RAISE EXCEPTION 'EVENT_REPLAY_CONFLICT' USING ERRCODE='22023';
  END IF;

  v_packet_record_preimage := jsonb_build_object(
    'schemaVersion',1,'packetId',(p_subject).packet_id,'packetVersion',1,
    'state','AWAITING_TERMINAL_BINDING','predecessorPacketVersion',NULL,
    'predecessorPacketRecordDigest',NULL,
    'packetSubjectDigest',v_packet_subject_digest,
    'memberSetDigest',v_member_set_digest,'terminalBindingDigest',NULL,
    'packetDigest',NULL,'outcomeFactId',NULL,'outcomeFactDigest',NULL,
    'finalizedAt',NULL,'invalidationAuthorityKind',NULL,
    'invalidationAuthorityId',NULL,'invalidationAuthorityVersion',NULL,
    'invalidationAuthorityDigest',NULL,'invalidationReason',NULL,
    'invalidatedAt',NULL
  );
  v_packet_record_preimage_canonical :=
    ops.canonical_jsonb_v1(v_packet_record_preimage);
  v_packet_record_digest := encode(extensions.digest(
    v_packet_record_preimage_canonical,'sha256'
  ),'hex');
  v_packet_record_payload := v_packet_record_preimage||jsonb_build_object(
    'packetRecordDigest',v_packet_record_digest
  );
  v_packet_record_canonical := ops.canonical_jsonb_v1(v_packet_record_payload);

  v_audit_id := ops.append_audit_event(
    'paid-evidence-packet:'||(p_subject).packet_id::text,
    'SERVICE','workflow-worker.paid-evidence-packet-materializer',NULL::uuid,
    'PAID_EVIDENCE_PACKET_SUBJECT_MATERIALIZED','PaidEvidencePacket',
    (p_subject).packet_id::text,NULL,'SUCCESS','DERIVED_AUTHORITY',
    v_request_id,jsonb_build_object(
      'packetId',(p_subject).packet_id,
      'packetVersion',1,'packetSubjectDigest',v_packet_subject_digest,
      'memberSetDigest',v_member_set_digest,
      'sourceEventId',(p_subject).source_event_id
    )
  );
  v_operation_receipt_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'domain','GURINE_PAID_PACKET_OPERATION_RECEIPT_V1',
      'schemaVersion',1,'packetId',(p_subject).packet_id,'packetVersion',1,
      'packetRecordDigest',v_packet_record_digest,'packetDigest',NULL,
      'outcomeFactId',NULL,'outcomeFactDigest',NULL,
      'auditEventIds',jsonb_build_array(v_audit_id),
      'outboxIds',jsonb_build_array(v_outbox_id),
      'sourceEventId',(p_subject).source_event_id,
      'bindingSourceEventId',NULL,'committedAt',v_now
    )),'sha256'
  ),'hex');

  INSERT INTO ops.paid_evidence_packets(
    packet_id,packet_version,state,deployment_id,organization_id,sku,
    qualification_receipt_id,qualification_episode_id,
    qualification_episode_version,qualification_episode_digest,
    commercial_contract_id,commercial_contract_version,
    commercial_contract_digest,review_snapshot_id,review_case_id,
    review_snapshot_version,review_snapshot_digest,review_member_set_digest,
    paid_member_manifest_digest,subject_kind,subject_delivery_id,
    subject_rendering_digest,subject_authorization_snapshot_digest,
    decision_cycle_id,decision_cycle_version,decision_cycle_digest,
    subject_binding_payload,subject_binding_canonical,packet_subject_digest,
    member_count,member_set_digest,source_event_id,
    source_event_envelope_digest,packet_record_payload,
    packet_record_canonical,packet_record_digest_preimage_canonical,
    packet_record_digest,packet_audit_event_id,packet_outbox_id,
    operation_receipt_digest,created_at
  ) VALUES (
    (p_subject).packet_id,1,'AWAITING_TERMINAL_BINDING',
    (p_subject).deployment_id,(p_subject).organization_id,(p_subject).sku,
    (p_subject).qualification_receipt_id,(p_subject).qualification_episode_id,
    (p_subject).qualification_episode_version,
    (p_subject).qualification_episode_digest,
    (p_subject).commercial_contract_id,(p_subject).commercial_contract_version,
    (p_subject).commercial_contract_digest,(p_subject).review_snapshot_id,
    v_snapshot.case_id,(p_subject).review_snapshot_version,
    (p_subject).review_snapshot_digest,v_snapshot.member_set_digest,
    (p_subject).paid_member_manifest_digest,v_subject_kind,
    v_subject_delivery_id,v_subject_rendering_digest,
    v_subject_authorization_snapshot_digest,v_decision_cycle_id,
    v_decision_cycle_version,v_decision_cycle_digest,v_subject_payload,
    v_subject_canonical,v_packet_subject_digest,10,v_member_set_digest,
    (p_subject).source_event_id,(p_subject).source_event_envelope_digest,
    v_packet_record_payload,v_packet_record_canonical,
    v_packet_record_preimage_canonical,v_packet_record_digest,v_audit_id,
    v_outbox_id,v_operation_receipt_digest,v_now
  );

  FOREACH v_member IN ARRAY (p_subject).ordered_members LOOP
    v_member_preimage := jsonb_build_object(
      'schemaVersion',1,'packetId',(p_subject).packet_id,
      'packetVersion',1,'memberOrdinal',v_member.member_ordinal,
      'category',v_member.category,'sourceSetId',v_member.source_set_id,
      'sourceSetVersion',v_member.source_set_version,
      'sourceSetDigest',v_member.source_set_digest,
      'dispositionKind',v_member.disposition_kind,
      'memberPayload',v_member.member_payload
    );
    v_member_preimage_canonical := ops.canonical_jsonb_v1(v_member_preimage);
    v_member_record_digest := encode(
      extensions.digest(v_member_preimage_canonical,'sha256'),'hex'
    );
    INSERT INTO ops.paid_evidence_packet_members(
      packet_id,packet_version,packet_subject_digest,
      packet_member_set_digest,member_ordinal,category,source_set_id,
      source_set_version,source_set_digest,disposition_kind,member_payload,
      member_canonical,member_digest_preimage_canonical,
      member_record_digest,created_at
    ) VALUES (
      (p_subject).packet_id,1,v_packet_subject_digest,v_member_set_digest,
      v_member.member_ordinal,v_member.category,v_member.source_set_id,
      v_member.source_set_version,v_member.source_set_digest,
      v_member.disposition_kind,v_member.member_payload,
      v_member.member_canonical,v_member_preimage_canonical,
      v_member_record_digest,v_now
    );
  END LOOP;

  v_event_payload := jsonb_build_object(
    'packetId',(p_subject).packet_id,'packetVersion',1,
    'organizationId',(p_subject).organization_id,
    'qualificationEpisodeId',(p_subject).qualification_episode_id,
    'qualificationEpisodeVersion',(p_subject).qualification_episode_version,
    'qualificationEpisodeDigest',(p_subject).qualification_episode_digest,
    'commercialContractId',(p_subject).commercial_contract_id,
    'commercialContractVersion',(p_subject).commercial_contract_version,
    'commercialContractDigest',(p_subject).commercial_contract_digest,
    'subjectKind',v_subject_kind,'packetSubjectDigest',v_packet_subject_digest,
    'memberCount',10,'memberSetDigest',v_member_set_digest,
    'state','AWAITING_TERMINAL_BINDING',
    'sourceEventId',(p_subject).source_event_id,
    'receiptDigest',v_operation_receipt_digest,'occurredAt',v_now
  );
  INSERT INTO ops.outbox(
    id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,
    occurred_at,available_at,attempt_count
  ) VALUES (
    v_outbox_id,'PaidEvidencePacket',(p_subject).packet_id::text,1,
    'product.paid_evidence_packet_subject_persisted.v1',v_event_payload,
    v_now,v_now,0
  );

  v_response := jsonb_build_object(
    'receiptId',(p_subject).packet_id,'packetId',(p_subject).packet_id,
    'packetVersion',1,'packetSubjectDigest',v_packet_subject_digest,
    'packetRecordDigest',v_packet_record_digest,'memberCount',10,
    'memberSetDigest',v_member_set_digest,'state','AWAITING_TERMINAL_BINDING',
    'sourceEventId',(p_subject).source_event_id,'auditEventId',v_audit_id,
    'outboxId',v_outbox_id,'receiptDigest',v_operation_receipt_digest,
    'occurredAt',v_now
  );
  v_response_bytes := ops.canonical_jsonb_v1(v_response);
  v_response_digest := encode(
    extensions.digest(v_response_bytes,'sha256'),'hex'
  );
  UPDATE ops.idempotency_keys SET
    response_status=201,response_body=v_response,
    resource_type='PAID_EVIDENCE_PACKET_SUBJECT',
    resource_id=(p_subject).packet_id::text,expires_at=v_now+interval '30 days'
  WHERE scope='ECONOMICS.MATERIALIZE_PAID_EVIDENCE_PACKET_SUBJECT.V1'
    AND key_hash=v_key_hash AND request_hash=v_request_hash;
  RETURN (
    (p_subject).packet_id,'PAID_EVIDENCE_PACKET_SUBJECT',
    (p_subject).packet_id,1,v_packet_record_digest,v_audit_id,v_outbox_id,
    201,'application/json',v_response_bytes,v_response_digest,
    v_operation_receipt_digest,v_now,false
  )::ops.economics_mutation_receipt_v1;
EXCEPTION
  WHEN invalid_text_representation OR invalid_datetime_format
       OR datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'PAID_EVIDENCE_MEMBER_SET_INVALID'
      USING ERRCODE='22023';
END
$r6e_paid_materialize$;
ALTER FUNCTION ops.materialize_paid_evidence_packet_subject_v1(
  ops.paid_evidence_packet_subject_input_v1,text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.materialize_paid_evidence_packet_subject_v1(
  ops.paid_evidence_packet_subject_input_v1,text
) FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_public_projector,
  gurine_public_api,gurine_submission_api,gurine_ingest_worker,
  gurine_notification_worker,gurine_scheduler,gurine_document_extractor,
  gurine_identity_api,gurine_auditor;

-- The terminal resolver registry, workflow HMAC authority, milestone proof,
-- metric policy and retention binding required to close this ABI do not yet
-- exist in the active authority.  Keep the declared catalog ABI available to
-- the migrator for schema closure, but fail before reading input or writing
-- any paid/outcome, audit, outbox or idempotency row.
CREATE FUNCTION ops.bind_paid_terminal_receipt_v1(
  p_binding ops.paid_terminal_binding_input_v1,
  p_idempotency_key text
) RETURNS ops.economics_mutation_receipt_v1
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,core,raw,intake,extensions,pg_temp
SET timezone='UTC'
AS $r6e_paid_terminal_bind$
BEGIN
  RAISE EXCEPTION 'PAID_PACKET_TERMINAL_NOT_READY'
    USING ERRCODE='55000';
END
$r6e_paid_terminal_bind$;
ALTER FUNCTION ops.bind_paid_terminal_receipt_v1(
  ops.paid_terminal_binding_input_v1,text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.bind_paid_terminal_receipt_v1(
  ops.paid_terminal_binding_input_v1,text
) FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_public_projector,
  gurine_public_api,gurine_submission_api,gurine_ingest_worker,
  gurine_notification_worker,gurine_scheduler,gurine_document_extractor,
  gurine_identity_api,gurine_auditor;
REVOKE USAGE ON TYPE ops.paid_evidence_packet_subject_input_v1,
  ops.paid_evidence_packet_member_input_v1,
  ops.paid_terminal_binding_input_v1
FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_public_projector,gurine_public_api,gurine_submission_api,
  gurine_ingest_worker,gurine_notification_worker,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor;

-- Product analytics is deliberately separate from the authoritative command
-- transaction, but it still has one closed owner boundary.  The caller's
-- digest is an assertion only: PostgreSQL derives the event digest from the
-- fixed, domain-separated projection and derives every retention field from
-- the current approved schedule.
CREATE FUNCTION ops.record_product_event_v1(
  p_emission_id uuid,
  p_event_name text,
  p_event_catalog_digest char(64),
  p_deployment_id uuid,
  p_workflow_instance_hmac char(64),
  p_workflow_key_version bigint,
  p_workflow_started_at timestamptz,
  p_workflow_expires_at timestamptz,
  p_occurred_at timestamptz,
  p_screen_id text,
  p_surface text,
  p_app_version text,
  p_specification_version text,
  p_properties jsonb,
  p_event_digest char(64)
) RETURNS ops.economics_mutation_receipt_v1
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
SET timezone='UTC'
AS $$
DECLARE
  v_catalog_digest constant char(64) :=
    '436c230e2de6edbd10c2d4f4d3f53df91147ad85bab3600cc8b0b945cf25528f';
  v_recorded_at timestamptz := clock_timestamp();
  v_event_id uuid := gen_random_uuid();
  v_surface text := split_part(p_event_name,'.',1);
  v_sensitivity text;
  v_record_class text;
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_existing ops.product_events%ROWTYPE;
  v_viewport_class text;
  v_success boolean;
  v_error_code text;
  v_internal_object_type text;
  v_workflow_stage text;
  v_result_code text;
  v_duration_bucket text;
  v_role_category text;
  v_public_object_type text;
  v_public_object_id text;
  v_state text;
  v_result_count_bucket text;
  v_filter_category_count smallint;
  v_step_id text;
  v_event_preimage bytea;
  v_derived_event_digest char(64);
  v_retention_deadline timestamptz;
  v_receipt_digest char(64);
  v_response jsonb;
  v_response_bytes bytea;
  v_response_digest char(64);
  v_idempotency_replay boolean := false;
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_workflow_worker'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'PRODUCT_EVENT_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_emission_id IS NULL OR p_deployment_id IS NULL
     OR p_event_name IS NULL OR p_screen_id IS NULL
     OR p_app_version IS NULL OR p_specification_version IS NULL
     OR p_workflow_started_at IS NULL OR p_workflow_expires_at IS NULL
     OR p_occurred_at IS NULL OR p_workflow_key_version IS NULL
     OR p_workflow_key_version <= 0
     OR p_workflow_instance_hmac IS NULL
     OR p_workflow_instance_hmac !~ '^[0-9a-f]{64}$'
     OR p_event_catalog_digest IS DISTINCT FROM v_catalog_digest
     OR p_event_digest IS NULL OR p_event_digest !~ '^[0-9a-f]{64}$'
     OR p_properties IS NULL OR jsonb_typeof(p_properties) <> 'object'
     OR p_event_name !~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$'
     OR length(p_event_name) > 128
     OR p_surface IS DISTINCT FROM v_surface
     OR v_surface NOT IN ('public','internal','response')
     OR p_workflow_started_at > p_occurred_at
     OR p_occurred_at >= p_workflow_expires_at
     OR (v_surface IN ('public','response')
         AND p_workflow_expires_at > p_workflow_started_at + interval '24 hours')
     OR (v_surface='internal'
         AND p_workflow_expires_at > p_workflow_started_at + interval '30 days')
     OR EXISTS (
       SELECT 1
       FROM jsonb_each(p_properties) AS property(name,value)
       WHERE name NOT IN (
         'viewport_class','success','error_code','internal_object_type',
         'workflow_stage','result_code','duration_bucket','role_category',
         'public_object_type','public_object_id','state','result_count_bucket',
         'filter_category_count','step_id'
       ) OR value='null'::jsonb
     )
     OR EXISTS (
       SELECT 1
       FROM jsonb_each(p_properties) AS property(name,value)
       WHERE (name='success' AND jsonb_typeof(value)<>'boolean')
          OR (name='filter_category_count' AND (
                jsonb_typeof(value)<>'number' OR value::text !~ '^[0-9]+$'))
          OR (name NOT IN ('success','filter_category_count')
              AND jsonb_typeof(value)<>'string')
     )
  THEN
    RAISE EXCEPTION 'PRODUCT_EVENT_INVALID' USING ERRCODE='22023';
  END IF;

  v_sensitivity := CASE v_surface
    WHEN 'public' THEN 'PUBLIC_PRODUCT'
    WHEN 'internal' THEN 'INTERNAL_OPERATIONAL'
    ELSE 'RESPONSE_SENSITIVE_MINIMAL'
  END;
  v_record_class := CASE v_surface
    WHEN 'public' THEN 'PRODUCT_ANALYTICS_PUBLIC'
    WHEN 'internal' THEN 'PRODUCT_ANALYTICS_INTERNAL'
    ELSE 'PRODUCT_ANALYTICS_RESPONSE'
  END;

  v_viewport_class := p_properties->>'viewport_class';
  v_success := CASE WHEN p_properties ? 'success'
    THEN (p_properties->>'success')::boolean END;
  v_error_code := p_properties->>'error_code';
  v_internal_object_type := p_properties->>'internal_object_type';
  v_workflow_stage := p_properties->>'workflow_stage';
  v_result_code := p_properties->>'result_code';
  v_duration_bucket := p_properties->>'duration_bucket';
  v_role_category := p_properties->>'role_category';
  v_public_object_type := p_properties->>'public_object_type';
  v_public_object_id := p_properties->>'public_object_id';
  v_state := p_properties->>'state';
  v_result_count_bucket := p_properties->>'result_count_bucket';
  v_filter_category_count := CASE
    WHEN p_properties ? 'filter_category_count'
    THEN (p_properties->>'filter_category_count')::smallint
  END;
  v_step_id := p_properties->>'step_id';

  v_event_preimage := ops.canonical_jsonb_v1(jsonb_build_object(
    'domain','GURINE_PRODUCT_EVENT_V1',
    'schemaVersion',1,
    'deploymentId',p_deployment_id,
    'emissionId',p_emission_id,
    'eventName',p_event_name,
    'sensitivity',v_sensitivity,
    'purposeCode','TASK_PROGRESSION_QUALITY_RECOVERY',
    'eventCatalogDigest',v_catalog_digest,
    'workflowInstanceHmac',p_workflow_instance_hmac,
    'workflowKeyVersion',p_workflow_key_version,
    'workflowStartedAt',p_workflow_started_at,
    'workflowExpiresAt',p_workflow_expires_at,
    'occurredAt',p_occurred_at,
    'screenId',p_screen_id,
    'surface',v_surface,
    'appVersion',p_app_version,
    'specificationVersion',p_specification_version,
    'viewportClass',v_viewport_class,
    'success',v_success,
    'errorCode',v_error_code,
    'internalObjectType',v_internal_object_type,
    'workflowStage',v_workflow_stage,
    'resultCode',v_result_code,
    'durationBucket',v_duration_bucket,
    'roleCategory',v_role_category,
    'publicObjectType',v_public_object_type,
    'publicObjectId',v_public_object_id,
    'state',v_state,
    'resultCountBucket',v_result_count_bucket,
    'filterCategoryCount',v_filter_category_count,
    'stepId',v_step_id
  ));
  v_derived_event_digest := encode(
    extensions.digest(v_event_preimage,'sha256'),'hex'
  );
  IF v_derived_event_digest IS DISTINCT FROM p_event_digest THEN
    RAISE EXCEPTION 'PRODUCT_EVENT_DIGEST_MISMATCH' USING ERRCODE='22023';
  END IF;

  -- One advisory identity lock makes same-emission replay deterministic without
  -- giving the owner role UPDATE on the append-only relation.
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'PRODUCT_EVENT:'||p_deployment_id::text||':'||p_emission_id::text,0
  ));
  SELECT * INTO v_existing
  FROM ops.product_events
  WHERE deployment_id=p_deployment_id AND emission_id=p_emission_id;
  IF FOUND THEN
    IF v_existing.event_digest IS DISTINCT FROM v_derived_event_digest THEN
      RAISE EXCEPTION 'FACT_CONFLICT' USING ERRCODE='40001';
    END IF;
    v_event_id := v_existing.id;
    v_recorded_at := v_existing.recorded_at;
    v_idempotency_replay := true;
  ELSE
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'RECORD_CLASS_SCHEDULE:'||v_record_class,0
    ));
    SELECT * INTO v_schedule
    FROM ops.record_class_schedules
    WHERE record_class=v_record_class
      AND effective_at<=v_recorded_at
      AND review_expires_at>v_recorded_at
    ORDER BY effective_at DESC,revision DESC,id DESC
    LIMIT 1;
    IF NOT FOUND OR v_schedule.active_duration_seconds IS NULL
       OR v_schedule.active_duration_seconds <= 0
       OR (v_surface='response'
           AND v_schedule.active_duration_seconds > 30*24*60*60)
       OR (v_surface IN ('public','internal')
           AND v_schedule.active_duration_seconds > 90*24*60*60)
    THEN
      RAISE EXCEPTION 'PRODUCT_EVENT_RETENTION_SCHEDULE_INVALID'
        USING ERRCODE='55000';
    END IF;
    v_retention_deadline := v_recorded_at
      + v_schedule.active_duration_seconds * interval '1 second';

    INSERT INTO ops.product_events(
      id,emission_id,event_name,sensitivity,purpose_code,
      event_catalog_digest,deployment_id,workflow_instance_hmac,
      workflow_key_version,workflow_started_at,workflow_expires_at,occurred_at,
      recorded_at,record_class,schedule_revision,schedule_digest,
      retention_deadline,screen_id,surface,app_version,specification_version,
      viewport_class,success,error_code,internal_object_type,workflow_stage,
      result_code,duration_bucket,role_category,public_object_type,
      public_object_id,state,result_count_bucket,filter_category_count,step_id,
      event_digest
    ) VALUES (
      v_event_id,p_emission_id,p_event_name,v_sensitivity,
      'TASK_PROGRESSION_QUALITY_RECOVERY',v_catalog_digest,p_deployment_id,
      p_workflow_instance_hmac,p_workflow_key_version,p_workflow_started_at,
      p_workflow_expires_at,p_occurred_at,v_recorded_at,v_record_class,
      v_schedule.revision,v_schedule.schedule_digest,v_retention_deadline,
      p_screen_id,v_surface,p_app_version,p_specification_version,
      v_viewport_class,v_success,v_error_code,v_internal_object_type,
      v_workflow_stage,v_result_code,v_duration_bucket,v_role_category,
      v_public_object_type,v_public_object_id,v_state,v_result_count_bucket,
      v_filter_category_count,v_step_id,v_derived_event_digest
    );
  END IF;

  v_receipt_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_ECONOMICS_MUTATION_RECEIPT_V1',
      'schemaVersion',1,
      'receiptId',v_event_id,
      'resourceType','PRODUCT_EVENT',
      'resourceId',v_event_id,
      'resourceVersion',1,
      'resourceDigest',v_derived_event_digest,
      'committedAt',v_recorded_at
    )
  ),'sha256'),'hex');
  v_response := jsonb_build_object(
    'receiptId',v_event_id,
    'resourceType','PRODUCT_EVENT',
    'resourceId',v_event_id,
    'resourceVersion',1,
    'resourceDigest',v_derived_event_digest,
    'receiptDigest',v_receipt_digest,
    'committedAt',v_recorded_at
  );
  v_response_bytes := ops.canonical_jsonb_v1(v_response);
  v_response_digest := encode(
    extensions.digest(v_response_bytes,'sha256'),'hex'
  );
  RETURN (
    v_event_id,'PRODUCT_EVENT',v_event_id,1,v_derived_event_digest,
    NULL,NULL,201,'application/json',v_response_bytes,v_response_digest,
    v_receipt_digest,v_recorded_at,v_idempotency_replay
  )::ops.economics_mutation_receipt_v1;
END
$$;
ALTER FUNCTION ops.record_product_event_v1(
  uuid,text,char(64),uuid,char(64),bigint,timestamptz,timestamptz,
  timestamptz,text,text,text,text,jsonb,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_product_event_v1(
  uuid,text,char(64),uuid,char(64),bigint,timestamptz,timestamptz,
  timestamptz,text,text,text,text,jsonb,char(64)
) FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_analysis_worker,gurine_public_projector,
  gurine_public_api,gurine_submission_api,gurine_ingest_worker,
  gurine_notification_worker,gurine_scheduler,gurine_document_extractor,
  gurine_identity_api,gurine_auditor;
GRANT EXECUTE ON FUNCTION ops.record_product_event_v1(
  uuid,text,char(64),uuid,char(64),bigint,timestamptz,timestamptz,
  timestamptz,text,text,text,text,jsonb,char(64)
) TO gurine_workflow_worker;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON ops.product_events
FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_public_projector,gurine_public_api,gurine_submission_api,
  gurine_ingest_worker,gurine_notification_worker,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor;

-- The 0030 event shape required a positive approved denominator and therefore
-- made the authoritative UNKNOWN branches impossible to emit.  This closed
-- forward schema preserves those branches without making any amount up.
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES (
  'governance.funding_snapshot_created.v1','DOMAIN',1,true,
  'payloads/governance_funding_snapshot_created_v1.schema.json',
  $schema${
    "$schema":"https://json-schema.org/draft/2020-12/schema",
    "$id":"https://gurine.invalid/events/governance.funding_snapshot_created.v1.schema.json",
    "type":"object","additionalProperties":false,
    "required":["snapshotBatchId","fiscalYear","asOf","reportingCurrency","fxSnapshotDigest","denominatorState","denominatorUnknownReason","denominator","denominatorApprovalDigest","entrySetDigest","snapshotDigest","receiptDigest"],
    "properties":{
      "snapshotBatchId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},
      "fiscalYear":{"type":"integer","minimum":1,"maximum":9999},
      "asOf":{"type":"string","format":"date-time"},
      "reportingCurrency":{"type":"string","pattern":"^[A-Z]{3}$"},
      "fxSnapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "denominatorState":{"type":"string","enum":["APPROVED","UNKNOWN"]},
      "denominatorUnknownReason":{"anyOf":[{"type":"null"},{"type":"string","enum":["MISSING","ZERO","APPROVAL_MISSING","APPROVAL_STALE"]}]},
      "denominator":{"anyOf":[{"type":"null"},{"type":"string","pattern":"^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$"}]},
      "denominatorApprovalDigest":{"anyOf":[{"type":"null"},{"type":"string","pattern":"^[0-9a-f]{64}$"}]},
      "entrySetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "snapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "receiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}
    }
  }$schema$::jsonb
) ON CONFLICT (event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;

CREATE FUNCTION ops.import_funding_snapshot_v1(
  p_import ops.funding_snapshot_import_v1,
  p_entries ops.funding_snapshot_entry_input_v1[]
) RETURNS ops.funding_snapshot_import_receipt_v1
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,core,editorial,extensions,pg_temp
SET timezone='UTC'
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_request_id uuid := gen_random_uuid();
  v_header_id uuid := gen_random_uuid();
  v_prior ops.funding_concentration_snapshots%ROWTYPE;
  v_existing ops.funding_concentration_snapshots%ROWTYPE;
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_key_hash char(64);
  v_request_hash char(64);
  v_snapshot_version bigint;
  v_entry_count integer := COALESCE(cardinality(p_entries),0);
  v_position integer := 0;
  v_entry ops.funding_snapshot_entry_input_v1;
  v_source record;
  v_source_index integer;
  v_entry_id uuid;
  v_group_digest char(64);
  v_entry_source_set_digest char(64);
  v_independent_review_digest char(64);
  v_entry_digest char(64);
  v_entry_digests char(64)[] := '{}'::char(64)[];
  v_entry_set_members jsonb := '[]'::jsonb;
  v_source_set_members jsonb := '[]'::jsonb;
  v_all_revenue_ids uuid[] := '{}'::uuid[];
  v_all_contract_ids uuid[] := '{}'::uuid[];
  v_all_external_ids uuid[] := '{}'::uuid[];
  v_external_fact_effects text[] := '{}'::text[];
  v_recognized numeric(24,6);
  v_binding numeric(24,6);
  v_numerator numeric(24,6);
  v_share numeric(24,6);
  v_band editorial.funding_concentration_band;
  v_unknown_reason ops.funding_concentration_unknown_reason;
  v_entry_set_digest char(64);
  v_source_set_digest char(64);
  v_snapshot_digest char(64);
  v_receipt_digest char(64);
  v_audit_id uuid;
  v_outbox_id uuid;
  v_response jsonb;
  v_response_bytes bytea;
  v_response_digest char(64);
  v_replay boolean := false;
  v_audit_actor_id text;
  v_audit_action text;
  v_audit_object_type text;
  v_audit_capability text;
  v_audit_reason text;
  v_audit_authority text;
  v_publication_authority text;
BEGIN
  IF current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'FUNDING_SNAPSHOT_OWNER_INTEGRITY_FAILED'
      USING ERRCODE='42501';
  END IF;
  CASE session_user
    WHEN 'gurine_workflow_worker' THEN
      v_audit_actor_id := 'workflow-worker';
      v_audit_action := 'IMPORT_FUNDING_SNAPSHOT';
      v_audit_object_type := 'FUNDING_SNAPSHOT';
      v_audit_capability := 'economics.import';
      v_audit_reason := 'SIGNED_FUNDING_SOURCES';
      v_audit_authority := 'SIGNED_IMPORT';
      v_publication_authority := 'NONE';
    WHEN 'gurine_public_projector' THEN
      v_audit_actor_id := 'funding-projector';
      v_audit_action := 'DONATION_FUNDING_CANDIDATE_PROJECTED';
      v_audit_object_type := 'FundingConcentrationSnapshot';
      v_audit_capability := NULL;
      v_audit_reason := 'AUTHENTICATED_DONATION_FACT';
      v_audit_authority := 'TEST_FIXTURE';
      v_publication_authority := 'NONE';
    ELSE
      RAISE EXCEPTION 'FUNDING_SNAPSHOT_PRODUCER_FORBIDDEN'
        USING ERRCODE='42501';
  END CASE;

  IF current_setting('transaction_isolation') <> 'serializable'
     OR (p_import).idempotency_key IS NULL
     OR length(btrim((p_import).idempotency_key)) NOT BETWEEN 1 AND 255
     OR (p_import).snapshot_batch_id IS NULL
     OR (p_import).fiscal_year NOT BETWEEN 1 AND 9999
     OR (p_import).as_of IS NULL OR (p_import).as_of > v_now
     OR (p_import).reporting_currency !~ '^[A-Z]{3}$'
     OR (p_import).funding_policy_version IS NULL
     OR length(btrim((p_import).funding_policy_version)) NOT BETWEEN 1 AND 128
     OR (p_import).funding_policy_digest !~ '^[0-9a-f]{64}$'
     OR (p_import).fx_snapshot_digest !~ '^[0-9a-f]{64}$'
     OR (p_import).expected_entry_set_digest !~ '^[0-9a-f]{64}$'
     OR (p_import).expected_source_set_digest !~ '^[0-9a-f]{64}$'
     OR (p_import).expected_snapshot_digest !~ '^[0-9a-f]{64}$'
     OR p_entries IS NULL OR v_entry_count > 10000
  THEN
    RAISE EXCEPTION 'FUNDING_SNAPSHOT_INVALID' USING ERRCODE='22023';
  END IF;

  IF NOT (
    (p_import).denominator_state='APPROVED'
    AND (p_import).denominator_amount>0
    AND (p_import).denominator_unknown_reason IS NULL
    AND (p_import).denominator_approval_digest ~ '^[0-9a-f]{64}$'
    AND (p_import).denominator_approver_set_digest ~ '^[0-9a-f]{64}$'
    AND (p_import).denominator_approved_at<=(p_import).as_of
    AND (p_import).denominator_approval_expires_at>(p_import).denominator_approved_at
    AND (p_import).as_of<(p_import).denominator_approval_expires_at
    OR (p_import).denominator_state='UNKNOWN'
    AND (p_import).denominator_unknown_reason='MISSING'
    AND (p_import).denominator_amount IS NULL
    AND num_nonnulls(
      (p_import).denominator_approval_digest,
      (p_import).denominator_approver_set_digest,
      (p_import).denominator_approved_at,
      (p_import).denominator_approval_expires_at
    )=0
    OR (p_import).denominator_state='UNKNOWN'
    AND (p_import).denominator_unknown_reason='ZERO'
    AND (p_import).denominator_amount=0
    AND num_nonnulls(
      (p_import).denominator_approval_digest,
      (p_import).denominator_approver_set_digest,
      (p_import).denominator_approved_at,
      (p_import).denominator_approval_expires_at
    )=0
    OR (p_import).denominator_state='UNKNOWN'
    AND (p_import).denominator_unknown_reason='APPROVAL_MISSING'
    AND (p_import).denominator_amount>0
    AND num_nonnulls(
      (p_import).denominator_approval_digest,
      (p_import).denominator_approver_set_digest,
      (p_import).denominator_approved_at,
      (p_import).denominator_approval_expires_at
    )=0
    OR (p_import).denominator_state='UNKNOWN'
    AND (p_import).denominator_unknown_reason='APPROVAL_STALE'
    AND (p_import).denominator_amount>0
    AND (p_import).denominator_approval_digest ~ '^[0-9a-f]{64}$'
    AND (p_import).denominator_approver_set_digest ~ '^[0-9a-f]{64}$'
    AND (p_import).denominator_approved_at<=(p_import).as_of
    AND (p_import).denominator_approval_expires_at>(p_import).denominator_approved_at
    AND (p_import).as_of>=(p_import).denominator_approval_expires_at
  ) THEN
    RAISE EXCEPTION 'FUNDING_DENOMINATOR_INVALID' USING ERRCODE='22023';
  END IF;

  v_key_hash := encode(extensions.digest(
    convert_to(btrim((p_import).idempotency_key),'UTF8'),'sha256'
  ),'hex');
  v_request_hash := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_IMPORT_REQUEST_V1',
      'schemaVersion',1,
      'header',to_jsonb(p_import),
      'entries',to_jsonb(p_entries)
    )
  ),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'ECONOMICS.IMPORT_FUNDING_SNAPSHOT.V1:'||v_key_hash,0
  ));
  SELECT * INTO v_idempotency
  FROM ops.idempotency_keys
  WHERE scope='ECONOMICS.IMPORT_FUNDING_SNAPSHOT.V1'
    AND key_hash=v_key_hash
  FOR UPDATE;
  IF FOUND THEN
    IF v_idempotency.request_hash IS DISTINCT FROM v_request_hash
       OR v_idempotency.response_status IS NULL
       OR v_idempotency.response_body IS NULL
    THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='40001';
    END IF;
    v_response := v_idempotency.response_body;
    v_response_bytes := ops.canonical_jsonb_v1(v_response);
    RETURN (
      (v_response->>'receiptId')::uuid,
      (v_response->>'snapshotHeaderId')::uuid,
      (v_response->>'snapshotBatchId')::uuid,
      (v_response->>'snapshotVersion')::bigint,
      (v_response->>'snapshotDigest')::char(64),
      (v_response->>'entryCount')::integer,
      (v_response->>'entrySetDigest')::char(64),
      (v_response->>'auditEventId')::uuid,
      (v_response->>'outboxId')::uuid,
      encode(extensions.digest(v_response_bytes,'sha256'),'hex')::char(64),
      (v_response->>'receiptDigest')::char(64),
      (v_response->>'committedAt')::timestamptz,
      true
    )::ops.funding_snapshot_import_receipt_v1;
  END IF;
  INSERT INTO ops.idempotency_keys(
    scope,key_hash,request_hash,resource_type,resource_id,expires_at
  ) VALUES (
    'ECONOMICS.IMPORT_FUNDING_SNAPSHOT.V1',v_key_hash,v_request_hash,
    'FUNDING_SNAPSHOT',(p_import).snapshot_batch_id::text,v_now+interval '24 hours'
  );

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'FUNDING_SNAPSHOT_FISCAL_YEAR:'||(p_import).fiscal_year::text,0
  ));
  SELECT * INTO v_prior
  FROM ops.funding_concentration_snapshots
  WHERE row_kind='SNAPSHOT_HEADER'
    AND fiscal_year=(p_import).fiscal_year
  ORDER BY snapshot_version DESC,id DESC
  LIMIT 1;
  IF FOUND THEN
    IF (p_import).expected_prior_header_id IS DISTINCT FROM v_prior.id
       OR (p_import).expected_prior_snapshot_digest
          IS DISTINCT FROM v_prior.snapshot_digest
    THEN
      RAISE EXCEPTION 'FUNDING_SNAPSHOT_PRIOR_CONFLICT' USING ERRCODE='40001';
    END IF;
    v_snapshot_version := v_prior.snapshot_version+1;
  ELSE
    IF (p_import).expected_prior_header_id IS NOT NULL
       OR (p_import).expected_prior_snapshot_digest IS NOT NULL
    THEN
      RAISE EXCEPTION 'FUNDING_SNAPSHOT_PRIOR_CONFLICT' USING ERRCODE='40001';
    END IF;
    v_snapshot_version := 1;
  END IF;
  SELECT * INTO v_existing
  FROM ops.funding_concentration_snapshots
  WHERE row_kind='SNAPSHOT_HEADER'
    AND snapshot_batch_id=(p_import).snapshot_batch_id;
  IF FOUND THEN
    RAISE EXCEPTION 'FACT_CONFLICT' USING ERRCODE='40001';
  END IF;

  FOREACH v_entry IN ARRAY p_entries LOOP
    v_position := v_position+1;
    v_external_fact_effects := '{}'::text[];
    IF v_entry.ordinal IS DISTINCT FROM v_position
       OR v_entry.counterparty_group_id IS NULL
       OR v_entry.grouping_state IS NULL
       OR v_entry.grouping_evidence_digest !~ '^[0-9a-f]{64}$'
       OR v_entry.member_supplier_ids IS NULL
       OR v_entry.member_supplier_identity_digests IS NULL
       OR cardinality(v_entry.member_supplier_ids)
          <> cardinality(v_entry.member_supplier_identity_digests)
       OR cardinality(v_entry.member_supplier_ids)>10000
       OR NOT ops.uuid_array_is_sorted_unique(v_entry.member_supplier_ids)
       OR v_entry.member_supplier_ids IS DISTINCT FROM ARRAY(
            SELECT member_id FROM unnest(v_entry.member_supplier_ids)
              AS member(member_id) ORDER BY member_id)
       OR EXISTS (
            SELECT 1 FROM unnest(v_entry.member_supplier_identity_digests)
              AS digest(value) WHERE value !~ '^[0-9a-f]{64}$')
       OR v_entry.related_case_ids IS NULL
       OR NOT ops.uuid_array_is_sorted_unique(v_entry.related_case_ids)
       OR v_entry.related_case_ids IS DISTINCT FROM ARRAY(
            SELECT case_id FROM unnest(v_entry.related_case_ids)
              AS related(case_id) ORDER BY case_id)
       OR (v_entry.grouping_state='RESOLVED'
           AND v_entry.grouping_dispute_reason IS NOT NULL)
       OR (v_entry.grouping_state='DISPUTED'
           AND v_entry.grouping_dispute_reason IS NULL)
       OR v_entry.expected_entry_source_set_digest !~ '^[0-9a-f]{64}$'
       OR v_entry.expected_independent_review_requirement_digest
          !~ '^[0-9a-f]{64}$'
       OR v_entry.expected_entry_digest !~ '^[0-9a-f]{64}$'
    THEN
      RAISE EXCEPTION 'FUNDING_SNAPSHOT_ENTRY_INVALID' USING ERRCODE='22023';
    END IF;
    IF v_entry.counterparty_group_id=ANY(ARRAY(
      SELECT prior.counterparty_group_id
      FROM unnest(p_entries[1:greatest(v_position-1,0)]) AS prior
    )) THEN
      RAISE EXCEPTION 'FUNDING_SNAPSHOT_GROUP_DUPLICATE' USING ERRCODE='22023';
    END IF;
    IF (SELECT count(*) FROM core.suppliers
        WHERE id=ANY(v_entry.member_supplier_ids))
       <> cardinality(v_entry.member_supplier_ids)
       OR (SELECT count(*) FROM editorial.cases
           WHERE id=ANY(v_entry.related_case_ids))
          <> cardinality(v_entry.related_case_ids)
    THEN
      RAISE EXCEPTION 'FUNDING_SNAPSHOT_SOURCE_NOT_FOUND' USING ERRCODE='P0002';
    END IF;

    IF v_entry.recognized_revenue_fact_ids IS NULL
       OR v_entry.recognized_revenue_fact_digests IS NULL
       OR v_entry.recognized_revenue_fact_amounts IS NULL
       OR cardinality(v_entry.recognized_revenue_fact_ids)
          <> cardinality(v_entry.recognized_revenue_fact_digests)
       OR cardinality(v_entry.recognized_revenue_fact_ids)
          <> cardinality(v_entry.recognized_revenue_fact_amounts)
       OR NOT ops.uuid_array_is_sorted_unique(v_entry.recognized_revenue_fact_ids)
       OR v_entry.recognized_revenue_fact_ids IS DISTINCT FROM ARRAY(
            SELECT source_id FROM unnest(v_entry.recognized_revenue_fact_ids)
              AS source(source_id) ORDER BY source_id)
       OR v_entry.binding_contract_period_ids IS NULL
       OR v_entry.binding_contract_period_digests IS NULL
       OR v_entry.binding_contract_period_amounts IS NULL
       OR cardinality(v_entry.binding_contract_period_ids)
          <> cardinality(v_entry.binding_contract_period_digests)
       OR cardinality(v_entry.binding_contract_period_ids)
          <> cardinality(v_entry.binding_contract_period_amounts)
       OR NOT ops.uuid_array_is_sorted_unique(v_entry.binding_contract_period_ids)
       OR v_entry.binding_contract_period_ids IS DISTINCT FROM ARRAY(
            SELECT source_id FROM unnest(v_entry.binding_contract_period_ids)
              AS source(source_id) ORDER BY source_id)
       OR v_entry.external_funding_source_receipt_ids IS NULL
       OR v_entry.external_funding_source_receipt_digests IS NULL
       OR v_entry.external_funding_source_signature_digests IS NULL
       OR v_entry.external_funding_source_kinds IS NULL
       OR v_entry.external_funding_amount_bases IS NULL
       OR v_entry.external_funding_source_amounts IS NULL
       OR cardinality(v_entry.external_funding_source_receipt_ids)
          <> cardinality(v_entry.external_funding_source_receipt_digests)
       OR cardinality(v_entry.external_funding_source_receipt_ids)
          <> cardinality(v_entry.external_funding_source_signature_digests)
       OR cardinality(v_entry.external_funding_source_receipt_ids)
          <> cardinality(v_entry.external_funding_source_kinds)
       OR cardinality(v_entry.external_funding_source_receipt_ids)
          <> cardinality(v_entry.external_funding_amount_bases)
       OR cardinality(v_entry.external_funding_source_receipt_ids)
          <> cardinality(v_entry.external_funding_source_amounts)
       OR NOT ops.uuid_array_is_sorted_unique(
            v_entry.external_funding_source_receipt_ids)
       OR v_entry.external_funding_source_receipt_ids IS DISTINCT FROM ARRAY(
            SELECT source_id
            FROM unnest(v_entry.external_funding_source_receipt_ids)
              AS source(source_id) ORDER BY source_id)
       OR cardinality(v_entry.recognized_revenue_fact_ids)
          + cardinality(v_entry.binding_contract_period_ids)
          + cardinality(v_entry.external_funding_source_receipt_ids)
          NOT BETWEEN 1 AND 10000
    THEN
      RAISE EXCEPTION 'FUNDING_SNAPSHOT_SOURCE_SET_INVALID'
        USING ERRCODE='22023';
    END IF;

    v_recognized := 0;
    FOR v_source_index IN 1..cardinality(v_entry.recognized_revenue_fact_ids)
    LOOP
      IF v_entry.recognized_revenue_fact_ids[v_source_index]=ANY(v_all_revenue_ids)
      THEN RAISE EXCEPTION 'FUNDING_SOURCE_REUSED' USING ERRCODE='22023'; END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended(
        'FUNDING_REVENUE_FACT:'||
        v_entry.recognized_revenue_fact_ids[v_source_index]::text,0
      ));
      SELECT id,record_digest,amount,currency,recognized_at
      INTO v_source
      FROM ops.revenue_facts
      WHERE id=v_entry.recognized_revenue_fact_ids[v_source_index];
      IF NOT FOUND
         OR v_source.record_digest IS DISTINCT FROM
            v_entry.recognized_revenue_fact_digests[v_source_index]
         OR v_source.amount IS DISTINCT FROM
            v_entry.recognized_revenue_fact_amounts[v_source_index]
         OR v_source.currency IS DISTINCT FROM (p_import).reporting_currency
         OR v_source.recognized_at>(p_import).as_of
      THEN
        RAISE EXCEPTION 'FUNDING_REVENUE_SOURCE_MISMATCH'
          USING ERRCODE='40001';
      END IF;
      v_recognized := v_recognized+v_source.amount;
      v_all_revenue_ids := array_append(v_all_revenue_ids,v_source.id);
    END LOOP;

    v_binding := 0;
    FOR v_source_index IN 1..cardinality(v_entry.binding_contract_period_ids)
    LOOP
      IF v_entry.binding_contract_period_ids[v_source_index]=ANY(v_all_contract_ids)
      THEN RAISE EXCEPTION 'FUNDING_SOURCE_REUSED' USING ERRCODE='22023'; END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended(
        'FUNDING_CONTRACT_PERIOD:'||
        v_entry.binding_contract_period_ids[v_source_index]::text,0
      ));
      SELECT c.id,c.record_digest,c.binding_committed_amount,c.currency,
             c.period_start,c.period_end,c.status,c.state_effective_at
      INTO v_source
      FROM ops.commercial_contract_periods c
      WHERE c.id=v_entry.binding_contract_period_ids[v_source_index]
        AND NOT EXISTS (
          SELECT 1 FROM ops.commercial_contract_periods successor
          WHERE successor.supersedes_contract_period_id=c.id
        );
      IF NOT FOUND
         OR v_source.record_digest IS DISTINCT FROM
            v_entry.binding_contract_period_digests[v_source_index]
         OR v_source.binding_committed_amount IS DISTINCT FROM
            v_entry.binding_contract_period_amounts[v_source_index]
         OR v_source.currency IS DISTINCT FROM (p_import).reporting_currency
         OR v_source.status NOT IN ('ACTIVE','SUSPENDED')
         OR v_source.state_effective_at>(p_import).as_of
         OR NOT (v_source.period_start<=(p_import).as_of::date
                 AND (p_import).as_of::date<v_source.period_end)
      THEN
        RAISE EXCEPTION 'FUNDING_CONTRACT_SOURCE_MISMATCH'
          USING ERRCODE='40001';
      END IF;
      v_binding := v_binding+v_source.binding_committed_amount;
      v_all_contract_ids := array_append(v_all_contract_ids,v_source.id);
    END LOOP;

    FOR v_source_index IN 1..cardinality(
      v_entry.external_funding_source_receipt_ids
    ) LOOP
      IF v_entry.external_funding_source_receipt_ids[v_source_index]
         =ANY(v_all_external_ids)
      THEN RAISE EXCEPTION 'FUNDING_SOURCE_REUSED' USING ERRCODE='22023'; END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended(
        'FUNDING_DONATION_FACT:'||
        v_entry.external_funding_source_receipt_ids[v_source_index]::text,0
      ));
      SELECT d.id,d.fact_digest,d.provider_fetch_digest,d.funding_source_kind,
             d.fact_effect,d.amount_basis,d.amount,d.currency,d.recognized_at
      INTO v_source
      FROM ops.donation_facts d
      WHERE d.id=v_entry.external_funding_source_receipt_ids[v_source_index]
        AND NOT EXISTS (
          SELECT 1 FROM ops.donation_facts successor
          WHERE successor.supersedes_fact_id=d.id
        );
      IF NOT FOUND
         OR v_source.fact_digest IS DISTINCT FROM
            v_entry.external_funding_source_receipt_digests[v_source_index]
         OR v_source.provider_fetch_digest IS DISTINCT FROM
            v_entry.external_funding_source_signature_digests[v_source_index]
         OR v_source.funding_source_kind IS DISTINCT FROM
            v_entry.external_funding_source_kinds[v_source_index]
         OR v_source.amount_basis IS DISTINCT FROM
            v_entry.external_funding_amount_bases[v_source_index]
         OR v_source.amount IS DISTINCT FROM
            v_entry.external_funding_source_amounts[v_source_index]
         OR v_source.currency IS DISTINCT FROM (p_import).reporting_currency
         OR v_source.recognized_at>(p_import).as_of
      THEN
        RAISE EXCEPTION 'FUNDING_EXTERNAL_SOURCE_MISMATCH'
          USING ERRCODE='40001';
      END IF;
      IF v_source.fact_effect='REVERSAL' THEN
        NULL;
      ELSIF v_source.amount_basis='RECOGNIZED' THEN
        v_recognized := v_recognized+v_source.amount;
      ELSE
        v_binding := v_binding+v_source.amount;
      END IF;
      v_external_fact_effects := array_append(
        v_external_fact_effects,v_source.fact_effect
      );
      v_all_external_ids := array_append(v_all_external_ids,v_source.id);
    END LOOP;

    v_numerator := v_recognized+v_binding;
    IF v_entry.grouping_state='DISPUTED' THEN
      v_share := NULL;
      v_band := 'UNKNOWN';
      v_unknown_reason := 'GROUPING_DISPUTED';
    ELSIF (p_import).denominator_state='UNKNOWN' THEN
      v_share := NULL;
      v_band := 'UNKNOWN';
      v_unknown_reason := 'DENOMINATOR_UNKNOWN';
    ELSE
      v_unknown_reason := NULL;
      v_share := ops.round_half_even_numeric_v1(
        v_numerator*100/(p_import).denominator_amount,6
      );
      v_band := CASE
        WHEN v_numerator*100<=(p_import).denominator_amount*5
          THEN 'LE_5_PERCENT'::editorial.funding_concentration_band
        WHEN v_numerator*100<=(p_import).denominator_amount*15
          THEN 'GT_5_TO_15_PERCENT'::editorial.funding_concentration_band
        WHEN v_numerator*100<=(p_import).denominator_amount*25
          THEN 'GT_15_TO_25_PERCENT'::editorial.funding_concentration_band
        ELSE 'GT_25_PERCENT'::editorial.funding_concentration_band
      END;
    END IF;

    v_group_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'domain','GURINE_FUNDING_COUNTERPARTY_GROUP_V1',
        'schemaVersion',1,
        'counterpartyGroupId',v_entry.counterparty_group_id,
        'groupingState',v_entry.grouping_state,
        'groupingDisputeReason',v_entry.grouping_dispute_reason,
        'groupingEvidenceDigest',v_entry.grouping_evidence_digest,
        'memberSupplierIds',v_entry.member_supplier_ids,
        'memberSupplierIdentityDigests',v_entry.member_supplier_identity_digests
      )
    ),'sha256'),'hex');
    IF v_group_digest IS DISTINCT FROM v_entry.counterparty_group_digest THEN
      RAISE EXCEPTION 'FUNDING_GROUP_DIGEST_MISMATCH' USING ERRCODE='22023';
    END IF;

    v_entry_source_set_digest := encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'domain','GURINE_FUNDING_ENTRY_SOURCE_SET_V1',
        'schemaVersion',1,
        'recognizedRevenueFactIds',v_entry.recognized_revenue_fact_ids,
        'recognizedRevenueFactDigests',v_entry.recognized_revenue_fact_digests,
        'recognizedRevenueFactAmounts',v_entry.recognized_revenue_fact_amounts,
        'bindingContractPeriodIds',v_entry.binding_contract_period_ids,
        'bindingContractPeriodDigests',v_entry.binding_contract_period_digests,
        'bindingContractPeriodAmounts',v_entry.binding_contract_period_amounts,
        'externalFundingSourceReceiptIds',
          v_entry.external_funding_source_receipt_ids,
        'externalFundingSourceReceiptDigests',
          v_entry.external_funding_source_receipt_digests,
        'externalFundingSourceSignatureDigests',
          v_entry.external_funding_source_signature_digests,
        'externalFundingSourceKinds',v_entry.external_funding_source_kinds,
        'externalFundingSourceFactEffects',v_external_fact_effects,
        'externalFundingAmountBases',v_entry.external_funding_amount_bases,
        'externalFundingSourceAmounts',v_entry.external_funding_source_amounts
      )),'sha256'),'hex');
    IF v_entry_source_set_digest IS DISTINCT FROM
       v_entry.expected_entry_source_set_digest THEN
      RAISE EXCEPTION 'FUNDING_SOURCE_SET_DIGEST_MISMATCH'
        USING ERRCODE='22023';
    END IF;

    v_independent_review_digest := encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'domain','GURINE_FUNDING_INDEPENDENT_REVIEW_REQUIREMENT_V1',
        'schemaVersion',1,
        'counterpartyGroupDigest',v_group_digest,
        'concentrationBand',v_band,
        'concentrationUnknownReason',v_unknown_reason,
        'investigatedSubjectRelated',v_entry.investigated_subject_related,
        'relatedParty',v_entry.related_party,
        'relatedCaseIds',v_entry.related_case_ids
      )),'sha256'),'hex');
    IF v_independent_review_digest IS DISTINCT FROM
       v_entry.expected_independent_review_requirement_digest THEN
      RAISE EXCEPTION 'FUNDING_REVIEW_DIGEST_MISMATCH'
        USING ERRCODE='22023';
    END IF;

    v_entry_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'domain','GURINE_FUNDING_SNAPSHOT_ENTRY_V1',
        'schemaVersion',1,
        'ordinal',v_entry.ordinal,
        'counterpartyGroupId',v_entry.counterparty_group_id,
        'counterpartyGroupDigest',v_group_digest,
        'groupingState',v_entry.grouping_state,
        'groupingDisputeReason',v_entry.grouping_dispute_reason,
        'groupingEvidenceDigest',v_entry.grouping_evidence_digest,
        'memberSupplierIds',v_entry.member_supplier_ids,
        'memberSupplierIdentityDigests',v_entry.member_supplier_identity_digests,
        'fundingSourceKind',v_entry.funding_source_kind,
        'recognizedRevenue',v_recognized,
        'bindingCommittedRevenue',v_binding,
        'numerator',v_numerator,
        'concentrationShare',v_share,
        'concentrationBand',v_band,
        'concentrationUnknownReason',v_unknown_reason,
        'governmentRelated',v_entry.government_related,
        'politicalPartyRelated',v_entry.political_party_related,
        'procurementSupplierRelated',v_entry.procurement_supplier_related,
        'investigatedSubjectRelated',v_entry.investigated_subject_related,
        'relatedParty',v_entry.related_party,
        'relatedCaseIds',v_entry.related_case_ids,
        'entrySourceSetDigest',v_entry_source_set_digest,
        'independentReviewRequirementDigest',v_independent_review_digest
      )
    ),'sha256'),'hex');
    IF v_entry_digest IS DISTINCT FROM v_entry.expected_entry_digest THEN
      RAISE EXCEPTION 'FUNDING_ENTRY_DIGEST_MISMATCH' USING ERRCODE='22023';
    END IF;

    v_entry_id := gen_random_uuid();
    INSERT INTO ops.funding_concentration_snapshots(
      id,snapshot_batch_id,snapshot_version,row_kind,ordinal,header_id,
      fiscal_year,as_of,reporting_currency,counterparty_group_id,
      counterparty_group_digest,grouping_state,grouping_dispute_reason,
      grouping_evidence_digest,member_supplier_ids,
      member_supplier_identity_digests,funding_source_kind,
      recognized_revenue,binding_committed_revenue,numerator,
      concentration_share,concentration_band,concentration_unknown_reason,
      government_related,political_party_related,procurement_supplier_related,
      investigated_subject_related,related_party,related_case_ids,
      recognized_revenue_fact_ids,recognized_revenue_fact_digests,
      recognized_revenue_fact_amounts,binding_contract_period_ids,
      binding_contract_period_digests,binding_contract_period_amounts,
      external_funding_source_receipt_ids,
      external_funding_source_receipt_digests,
      external_funding_source_signature_digests,external_funding_source_kinds,
      external_funding_amount_bases,external_funding_source_amounts,
      entry_source_set_digest,independent_review_requirement_digest,entry_digest
    ) VALUES (
      v_entry_id,(p_import).snapshot_batch_id,v_snapshot_version,
      'COUNTERPARTY_ENTRY',v_entry.ordinal,v_header_id,(p_import).fiscal_year,
      (p_import).as_of,(p_import).reporting_currency,
      v_entry.counterparty_group_id,v_group_digest,v_entry.grouping_state,
      v_entry.grouping_dispute_reason,v_entry.grouping_evidence_digest,
      v_entry.member_supplier_ids,v_entry.member_supplier_identity_digests,
      v_entry.funding_source_kind,v_recognized,v_binding,v_numerator,v_share,
      v_band,v_unknown_reason,v_entry.government_related,
      v_entry.political_party_related,v_entry.procurement_supplier_related,
      v_entry.investigated_subject_related,v_entry.related_party,
      v_entry.related_case_ids,v_entry.recognized_revenue_fact_ids,
      v_entry.recognized_revenue_fact_digests,
      v_entry.recognized_revenue_fact_amounts,
      v_entry.binding_contract_period_ids,v_entry.binding_contract_period_digests,
      v_entry.binding_contract_period_amounts,
      v_entry.external_funding_source_receipt_ids,
      v_entry.external_funding_source_receipt_digests,
      v_entry.external_funding_source_signature_digests,
      v_entry.external_funding_source_kinds,v_entry.external_funding_amount_bases,
      v_entry.external_funding_source_amounts,v_entry_source_set_digest,
      v_independent_review_digest,v_entry_digest
    );
    v_entry_digests := array_append(v_entry_digests,v_entry_digest);
    v_entry_set_members := v_entry_set_members || jsonb_build_array(
      jsonb_build_object('ordinal',v_entry.ordinal,'entryDigest',v_entry_digest)
    );
    v_source_set_members := v_source_set_members || jsonb_build_array(
      jsonb_build_object(
        'ordinal',v_entry.ordinal,
        'entrySourceSetDigest',v_entry_source_set_digest
      )
    );
  END LOOP;

  v_entry_set_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_ENTRY_SET_V1',
      'schemaVersion',1,'entries',v_entry_set_members
    )
  ),'sha256'),'hex');
  v_source_set_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_SOURCE_SET_V1',
      'schemaVersion',1,'sources',v_source_set_members
    )
  ),'sha256'),'hex');
  IF v_entry_set_digest IS DISTINCT FROM (p_import).expected_entry_set_digest
     OR v_source_set_digest IS DISTINCT FROM (p_import).expected_source_set_digest
  THEN
    RAISE EXCEPTION 'FUNDING_SNAPSHOT_SET_DIGEST_MISMATCH'
      USING ERRCODE='22023';
  END IF;
  v_snapshot_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_V1',
      'schemaVersion',1,
      'snapshotBatchId',(p_import).snapshot_batch_id,
      'snapshotVersion',v_snapshot_version,
      'fiscalYear',(p_import).fiscal_year,
      'asOf',(p_import).as_of,
      'reportingCurrency',(p_import).reporting_currency,
      'priorHeaderId',CASE WHEN v_snapshot_version=1 THEN NULL ELSE v_prior.id END,
      'priorSnapshotDigest',CASE WHEN v_snapshot_version=1
        THEN NULL ELSE v_prior.snapshot_digest END,
      'fundingPolicyVersion',(p_import).funding_policy_version,
      'fundingPolicyDigest',(p_import).funding_policy_digest,
      'fxSnapshotDigest',(p_import).fx_snapshot_digest,
      'denominatorAmount',(p_import).denominator_amount,
      'denominatorState',(p_import).denominator_state,
      'denominatorUnknownReason',(p_import).denominator_unknown_reason,
      'denominatorApprovalDigest',(p_import).denominator_approval_digest,
      'denominatorApproverSetDigest',
        (p_import).denominator_approver_set_digest,
      'denominatorApprovedAt',(p_import).denominator_approved_at,
      'denominatorApprovalExpiresAt',
        (p_import).denominator_approval_expires_at,
      'entryCount',v_entry_count,
      'entrySetDigest',v_entry_set_digest,
      'sourceSetDigest',v_source_set_digest
    )
  ),'sha256'),'hex');
  IF v_snapshot_digest IS DISTINCT FROM (p_import).expected_snapshot_digest THEN
    RAISE EXCEPTION 'FUNDING_SNAPSHOT_DIGEST_MISMATCH' USING ERRCODE='22023';
  END IF;
  v_receipt_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_IMPORT_RECEIPT_V1',
      'schemaVersion',1,
      'receiptId',v_header_id,
      'snapshotHeaderId',v_header_id,
      'snapshotBatchId',(p_import).snapshot_batch_id,
      'snapshotVersion',v_snapshot_version,
      'snapshotDigest',v_snapshot_digest,
      'entryCount',v_entry_count,
      'entrySetDigest',v_entry_set_digest,
      'committedAt',v_now
    )
  ),'sha256'),'hex');
  v_audit_id := ops.append_audit_event(
    'economics.funding_snapshot:'||(p_import).snapshot_batch_id::text,
    'SERVICE',v_audit_actor_id,NULL,v_audit_action,
    v_audit_object_type,(p_import).snapshot_batch_id::text,
    v_audit_capability,'SUCCESS',v_audit_reason,v_request_id,
    jsonb_build_object(
      'snapshotVersion',v_snapshot_version,
      'snapshotDigest',v_snapshot_digest,
      'entryCount',v_entry_count,
      'entrySetDigest',v_entry_set_digest,
      'sourceSetDigest',v_source_set_digest,
      'authority',v_audit_authority,
      'publicationAuthority',v_publication_authority
    )
  );
  v_outbox_id := ops.enqueue_outbox(
    'FundingConcentrationSnapshot',(p_import).snapshot_batch_id::text,
    v_snapshot_version,
    'governance.funding_snapshot_created.v1',
    jsonb_build_object(
      'snapshotBatchId',(p_import).snapshot_batch_id,
      'fiscalYear',(p_import).fiscal_year,
      'asOf',(p_import).as_of,
      'reportingCurrency',(p_import).reporting_currency,
      'fxSnapshotDigest',(p_import).fx_snapshot_digest,
      'denominatorState',(p_import).denominator_state,
      'denominatorUnknownReason',(p_import).denominator_unknown_reason,
      'denominator',CASE WHEN (p_import).denominator_amount IS NULL
        THEN NULL ELSE (p_import).denominator_amount::text END,
      'denominatorApprovalDigest',(p_import).denominator_approval_digest,
      'entrySetDigest',v_entry_set_digest,
      'snapshotDigest',v_snapshot_digest,
      'receiptDigest',v_receipt_digest
    ),v_now
  );
  INSERT INTO ops.funding_concentration_snapshots(
    id,snapshot_batch_id,snapshot_version,row_kind,ordinal,fiscal_year,as_of,
    reporting_currency,prior_header_id,prior_snapshot_digest,
    funding_policy_version,funding_policy_digest,fx_snapshot_digest,
    denominator_amount,denominator_state,denominator_unknown_reason,
    denominator_approval_digest,denominator_approver_set_digest,
    denominator_approved_at,denominator_approval_expires_at,entry_count,
    entry_set_digest,source_set_digest,snapshot_digest,import_receipt_digest,
    audit_event_id,outbox_id,imported_at
  ) VALUES (
    v_header_id,(p_import).snapshot_batch_id,v_snapshot_version,
    'SNAPSHOT_HEADER',0,(p_import).fiscal_year,(p_import).as_of,
    (p_import).reporting_currency,
    CASE WHEN v_snapshot_version=1 THEN NULL ELSE v_prior.id END,
    CASE WHEN v_snapshot_version=1 THEN NULL ELSE v_prior.snapshot_digest END,
    (p_import).funding_policy_version,(p_import).funding_policy_digest,
    (p_import).fx_snapshot_digest,(p_import).denominator_amount,
    (p_import).denominator_state,(p_import).denominator_unknown_reason,
    (p_import).denominator_approval_digest,
    (p_import).denominator_approver_set_digest,
    (p_import).denominator_approved_at,
    (p_import).denominator_approval_expires_at,v_entry_count,
    v_entry_set_digest,v_source_set_digest,v_snapshot_digest,v_receipt_digest,
    v_audit_id,v_outbox_id,v_now
  );
  v_response := jsonb_build_object(
    'receiptId',v_header_id,
    'snapshotHeaderId',v_header_id,
    'snapshotBatchId',(p_import).snapshot_batch_id,
    'snapshotVersion',v_snapshot_version,
    'snapshotDigest',v_snapshot_digest,
    'entryCount',v_entry_count,
    'entrySetDigest',v_entry_set_digest,
    'auditEventId',v_audit_id,
    'outboxId',v_outbox_id,
    'receiptDigest',v_receipt_digest,
    'committedAt',v_now
  );
  v_response_bytes := ops.canonical_jsonb_v1(v_response);
  v_response_digest := encode(extensions.digest(v_response_bytes,'sha256'),'hex');
  UPDATE ops.idempotency_keys SET
    response_status=201,response_body=v_response,
    resource_type='FUNDING_SNAPSHOT',resource_id=v_header_id::text,
    expires_at=v_now+interval '24 hours'
  WHERE scope='ECONOMICS.IMPORT_FUNDING_SNAPSHOT.V1' AND key_hash=v_key_hash;
  RETURN (
    v_header_id,v_header_id,(p_import).snapshot_batch_id,v_snapshot_version,
    v_snapshot_digest,v_entry_count,v_entry_set_digest,v_audit_id,v_outbox_id,
    v_response_digest,v_receipt_digest,v_now,v_replay
  )::ops.funding_snapshot_import_receipt_v1;
END
$$;
ALTER FUNCTION ops.import_funding_snapshot_v1(
  ops.funding_snapshot_import_v1,ops.funding_snapshot_entry_input_v1[]
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.import_funding_snapshot_v1(
  ops.funding_snapshot_import_v1,ops.funding_snapshot_entry_input_v1[]
) FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_analysis_worker,gurine_public_projector,
  gurine_public_api,gurine_submission_api,gurine_ingest_worker,
  gurine_notification_worker,gurine_scheduler,gurine_document_extractor,
  gurine_identity_api,gurine_auditor;
GRANT EXECUTE ON FUNCTION ops.import_funding_snapshot_v1(
  ops.funding_snapshot_import_v1,ops.funding_snapshot_entry_input_v1[]
) TO gurine_workflow_worker;
REVOKE ALL ON TYPE ops.funding_snapshot_import_v1,
  ops.funding_snapshot_entry_input_v1,ops.funding_snapshot_import_receipt_v1
FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway;
GRANT USAGE ON TYPE ops.funding_snapshot_import_v1,
  ops.funding_snapshot_entry_input_v1,ops.funding_snapshot_import_receipt_v1
TO gurine_workflow_worker;
CREATE TRIGGER funding_concentration_snapshots_r6e_immutable
  BEFORE UPDATE OR DELETE ON ops.funding_concentration_snapshots
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON ops.funding_concentration_snapshots
FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_public_projector,gurine_public_api,gurine_submission_api,
  gurine_ingest_worker,gurine_notification_worker,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor;

-- R6E_SKU_READINESS_OWNER_FUNCTION

-- The two aggregate readers below predate the typed readiness writer and
-- return JSON.  Keep that untyped surface behind one owner-private decoder:
-- callers cannot select a metric, inject a value, or substitute an input-set
-- digest, and any field-set drift fails closed before a readiness row exists.
CREATE FUNCTION ops.read_sku_readiness_metric_authority_v1(
  p_deployment_id uuid,
  p_organization_id uuid,
  p_as_of timestamptz,
  p_metric_id text
) RETURNS TABLE(
  metric_status text,
  observed_value numeric(24,6),
  source_input_digest char(64),
  evidence_as_of timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
SET timezone='UTC'
AS $$
DECLARE
  v_projection jsonb;
  v_metric jsonb;
  v_result jsonb;
  v_match_count integer;
BEGIN
  IF p_deployment_id IS NULL OR p_organization_id IS NULL OR p_as_of IS NULL
     OR p_metric_id NOT IN (
       'BM-SUPPORT-HOURS-PER-ACTIVATED-ORG',
       'BM-CAC-PAYBACK-MONTHS'
     )
  THEN
    RAISE EXCEPTION 'SKU_READINESS_METRIC_INPUT_INVALID'
      USING ERRCODE='22023';
  END IF;

  IF p_metric_id='BM-SUPPORT-HOURS-PER-ACTIVATED-ORG' THEN
    v_projection := ops.read_commercial_eligibility_inputs_v1(
      p_deployment_id,p_organization_id,p_as_of
    );
    IF NOT ops.jsonb_object_has_exact_keys_v1(
         v_projection,ARRAY['asOf','support','expansion','renewal']::text[]
       ) OR NOT ops.jsonb_object_has_exact_keys_v1(
         v_projection->'support',ARRAY[
           'status','reasonCode','hours','totalHours','denominatorCount',
           'completeMonthCount','unknownCount','inputSetDigest'
         ]::text[]
       )
    THEN
      RAISE EXCEPTION 'SKU_READINESS_SUPPORT_READER_DRIFT'
        USING ERRCODE='55000';
    END IF;
    v_metric := v_projection->'support';
    metric_status := v_metric->>'status';
    source_input_digest := (v_metric->>'inputSetDigest')::char(64);
    evidence_as_of := (v_projection->>'asOf')::timestamptz;
    IF metric_status NOT IN ('KNOWN','UNKNOWN','NOT_APPLICABLE')
       OR source_input_digest !~ '^[0-9a-f]{64}$'
       OR evidence_as_of IS DISTINCT FROM p_as_of
       OR (metric_status='KNOWN' AND (
         jsonb_typeof(v_metric->'hours')<>'number'
         OR jsonb_typeof(v_metric->'totalHours')<>'number'
         OR jsonb_typeof(v_metric->'denominatorCount')<>'number'
         OR (v_metric->>'denominatorCount')::numeric<=0
       ))
       OR (metric_status<>'KNOWN' AND v_metric->'hours'<>'null'::jsonb)
    THEN
      RAISE EXCEPTION 'SKU_READINESS_SUPPORT_READER_INVALID'
        USING ERRCODE='55000';
    END IF;
    observed_value := CASE WHEN metric_status='KNOWN'
      THEN (v_metric->>'hours')::numeric(24,6) END;
    RETURN NEXT;
    RETURN;
  END IF;

  v_projection := ops.read_business_health_projection_v1(
    p_deployment_id,p_organization_id,p_as_of
  );
  IF NOT ops.jsonb_object_has_exact_keys_v1(v_projection,ARRAY[
       'asOf','specificationVersion','metricCatalogDigest','funnel','metrics',
       'topIssue','readinessState','unknownSourceCount','nextReviewAt'
     ]::text[])
     OR jsonb_typeof(v_projection->'metrics')<>'array'
  THEN
    RAISE EXCEPTION 'SKU_READINESS_HEALTH_READER_DRIFT'
      USING ERRCODE='55000';
  END IF;
  SELECT count(*),(jsonb_agg(metric.value)->0)
    INTO v_match_count,v_metric
  FROM jsonb_array_elements(v_projection->'metrics') AS metric(value)
  WHERE metric.value->>'metricId'=p_metric_id;
  IF v_match_count<>1 OR NOT ops.jsonb_object_has_exact_keys_v1(v_metric,ARRAY[
       'metricId','metricVersion','formulaDigest','policyDigest',
       'inputSetDigest','status','reasonCode','resultKind','result',
       'eligibleCount','pendingCount','unknownCount','unknownReasons',
       'windowStart','windowEnd','accountingTimezone','asOf','latestSourceAt',
       'freshUntil','thresholdState','issueCode','breachAction','owner'
     ]::text[])
  THEN
    RAISE EXCEPTION 'SKU_READINESS_CAC_READER_DRIFT'
      USING ERRCODE='55000';
  END IF;
  v_result := v_metric->'result';
  IF NOT ops.jsonb_object_has_exact_keys_v1(v_result,ARRAY[
       'kind','numerator','denominator','ratio','unit','resultDigest'
     ]::text[])
  THEN
    RAISE EXCEPTION 'SKU_READINESS_CAC_RESULT_DRIFT'
      USING ERRCODE='55000';
  END IF;
  metric_status := v_metric->>'status';
  source_input_digest := (v_metric->>'inputSetDigest')::char(64);
  evidence_as_of := (v_metric->>'asOf')::timestamptz;
  IF metric_status NOT IN ('KNOWN','UNKNOWN','NOT_APPLICABLE')
     OR v_metric->>'resultKind'<>'DETERMINISTIC_RATIO'
     OR v_result->>'kind'<>'DETERMINISTIC_RATIO'
     OR v_result->>'unit'<>'months'
     OR v_result->>'resultDigest' IS DISTINCT FROM
        v_metric->>'inputSetDigest'
     OR source_input_digest !~ '^[0-9a-f]{64}$'
     OR evidence_as_of IS DISTINCT FROM p_as_of
     OR (metric_status='KNOWN' AND (
       jsonb_typeof(v_result->'ratio')<>'number'
       OR jsonb_typeof(v_result->'numerator')<>'string'
       OR jsonb_typeof(v_result->'denominator')<>'string'
       OR (v_result->>'denominator')::numeric<=0
     ))
     OR (metric_status<>'KNOWN' AND v_result->'ratio'<>'null'::jsonb)
  THEN
    RAISE EXCEPTION 'SKU_READINESS_CAC_READER_INVALID'
      USING ERRCODE='55000';
  END IF;
  observed_value := CASE WHEN metric_status='KNOWN'
    THEN (v_result->>'ratio')::numeric(24,6) END;
  RETURN NEXT;
END
$$;
ALTER FUNCTION ops.read_sku_readiness_metric_authority_v1(
  uuid,uuid,timestamptz,text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_sku_readiness_metric_authority_v1(
  uuid,uuid,timestamptz,text
) FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_public_projector,gurine_public_api,gurine_submission_api,
  gurine_ingest_worker,gurine_notification_worker,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor;
-- The base v13 check paired every threshold with an observed value, which made
-- the catalog's required UNKNOWN state physically impossible.  A threshold is
-- still mandatory; only UNKNOWN and non-offered rows may omit an observation.
ALTER TABLE ops.sku_readiness_items
  DROP CONSTRAINT sku_readiness_items_measurement_presence_ck;
ALTER TABLE ops.sku_readiness_items
  ADD CONSTRAINT sku_readiness_items_measurement_presence_ck CHECK (
    threshold_value IS NOT NULL
    AND (observed_value IS NOT NULL
      OR item_state IN ('UNKNOWN','NOT_APPLICABLE'))
  );

-- The caller supplies only authority references and measured values.  Catalog
-- membership, requirement class, thresholds, verdicts, counts and every
-- persisted digest are derived below, so a fixture or stale worker cannot
-- declare itself READY.
CREATE TYPE ops.sku_readiness_evaluation_input_v1 AS (
  idempotency_key text,
  deployment_id uuid,
  organization_id uuid,
  sku ops.commercial_sku,
  environment text,
  readiness_stage text,
  configuration_digest char(64),
  policy_digest char(64),
  offered_optional_capability_ids text[],
  evaluated_at timestamptz,
  evidence_cutoff_at timestamptz,
  evaluator_build_digest char(64)
);
ALTER TYPE ops.sku_readiness_evaluation_input_v1 OWNER TO gurine_migrator;
REVOKE ALL ON TYPE ops.sku_readiness_evaluation_input_v1 FROM PUBLIC;

CREATE TYPE ops.sku_readiness_item_input_v1 AS (
  item_code text,
  evidence_tier text,
  expected_configuration_digest char(64),
  activation_decision_id uuid,
  activation_decision_version bigint,
  activation_decision_digest char(64),
  activation_evidence_id uuid,
  activation_evidence_digest char(64),
  commercial_contract_period_id uuid,
  commercial_contract_record_digest char(64),
  tariff_version_id uuid,
  tariff_record_digest char(64),
  invoice_fact_id uuid,
  invoice_reconciliation_digest char(64),
  revenue_fact_id uuid,
  revenue_record_digest char(64),
  cost_allocation_period_id uuid,
  cost_allocation_row_kind text,
  cost_allocation_record_digest char(64),
  cost_allocation_close_receipt_digest char(64),
  outcome_fact_id uuid,
  outcome_fact_digest char(64),
  sli_window_receipt_id uuid,
  sli_id text,
  sli_definition_version text,
  sli_environment text,
  sli_scope_digest char(64),
  sli_window_kind text,
  sli_window_sequence bigint,
  sli_organization_id uuid,
  sli_contract_period_id uuid,
  sli_policy_digest char(64),
  sli_receipt_digest char(64),
  evidence_member_set_digest char(64),
  evidence_as_of timestamptz,
  evidence_expires_at timestamptz,
  observed_value numeric(24,6),
  owner_function text
);
ALTER TYPE ops.sku_readiness_item_input_v1 OWNER TO gurine_migrator;
REVOKE ALL ON TYPE ops.sku_readiness_item_input_v1 FROM PUBLIC;

-- 0030's legacy event schema omitted the closed UNKNOWN evaluation state and
-- most rebuild fields.  Forward-freeze the complete deterministic payload.
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES (
  'commercial.sku_readiness_evaluated.v1','DOMAIN',1,true,
  'payloads/commercial_sku_readiness_evaluated_v1.schema.json',
  $schema${
    "$schema":"https://json-schema.org/draft/2020-12/schema",
    "$id":"https://gurine.invalid/events/commercial.sku_readiness_evaluated.v1.schema.json",
    "type":"object","additionalProperties":false,
    "required":["evaluationId","deploymentId","organizationId","sku","environment","readinessStage","configurationDigest","catalogVersion","catalogDigest","policyDigest","offeredCapabilitySetDigest","itemIdentitySetDigest","evaluationIdentityDigest","evaluatedAt","evidenceCutoffAt","itemCount","requiredItemCount","satisfiedRequiredItemCount","blockedRequiredItemCount","unknownRequiredItemCount","itemSetDigest","state","blockerSetDigest","evaluationDigest","receiptDigest"],
    "properties":{
      "evaluationId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},
      "deploymentId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},
      "organizationId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},
      "sku":{"type":"string","enum":["EVIDENCE_WORKSPACE_ORGANIZATION_V1"]},
      "environment":{"type":"string","enum":["development","test","staging","production"]},
      "readinessStage":{"type":"string","enum":["PILOT_ENTRY_READINESS","POST_FIRST_BILLING_CYCLE","GENERAL_AVAILABILITY"]},
      "configurationDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "catalogVersion":{"type":"string","const":"evidence-workspace-readiness.v1"},
      "catalogDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "policyDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "offeredCapabilitySetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "itemIdentitySetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "evaluationIdentityDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "evaluatedAt":{"type":"string","format":"date-time"},
      "evidenceCutoffAt":{"type":"string","format":"date-time"},
      "itemCount":{"type":"integer","minimum":1},
      "requiredItemCount":{"type":"integer","minimum":1},
      "satisfiedRequiredItemCount":{"type":"integer","minimum":0},
      "blockedRequiredItemCount":{"type":"integer","minimum":0},
      "unknownRequiredItemCount":{"type":"integer","minimum":0},
      "itemSetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "state":{"type":"string","enum":["READY","BLOCKED","UNKNOWN"]},
      "blockerSetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "evaluationDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "receiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}
    }
  }$schema$::jsonb
) ON CONFLICT (event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;

-- R6E_SKU_READINESS_OWNER_FUNCTION_BODY

CREATE FUNCTION ops.record_sku_readiness_evaluation_v1(
  p_evaluation ops.sku_readiness_evaluation_input_v1,
  p_items ops.sku_readiness_item_input_v1[]
) RETURNS ops.economics_mutation_receipt_v1
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
SET timezone='UTC'
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_evaluation_id uuid := gen_random_uuid();
  v_item_id uuid;
  v_item_ordinal integer := 0;
  v_item ops.sku_readiness_item_input_v1;
  v_effective_evidence_tier text;
  v_effective_cost_allocation_period_id uuid;
  v_effective_cost_allocation_row_kind text;
  v_effective_cost_allocation_record_digest char(64);
  v_effective_cost_allocation_close_receipt_digest char(64);
  v_effective_evidence_member_set_digest char(64);
  v_effective_evidence_as_of timestamptz;
  v_effective_evidence_expires_at timestamptz;
  v_effective_observed_value numeric(24,6);
  v_all_codes constant text[] := ARRAY[
    'PAID_WORKSPACE_PROCESSING_ACTIVE',
    'DEPLOYMENT_ISOLATION_PROVEN',
    'OIDC_AND_ROSTER_READY',
    'DATA_STORES_KEYS_QUEUES_ISOLATED',
    'SOURCE_RIGHTS_CONFIGURED',
    'TELEMETRY_ALERTS_RUNBOOK_READY',
    'BACKUP_RESTORE_PROVEN',
    'INCIDENT_OWNERSHIP_READY',
    'PUBLIC_WEB_ACTIVE',
    'VERIFIED_EMAIL_ACTIVE',
    'API_EXPORT_ACTIVE',
    'SIGNED_WEBHOOK_ACTIVE',
    'DAILY_DIGEST_ACTIVE',
    'WEEKLY_DIGEST_ACTIVE',
    'CURRENT_CONTRACT_PERIOD',
    'CURRENT_TARIFF_VERSION',
    'BILLING_RECONCILIATION_PATH_READY',
    'COST_CAPTURE_PATH_READY',
    'P75_VARIABLE_GROSS_MARGIN',
    'SUPPORT_CAPACITY',
    'ACTUAL_BILLABLE_RECONCILIATION',
    'ACTUAL_COST_CAPTURE',
    'FIRST_PAID_VERIFIED_WORKFLOW_CYCLE',
    'CAC_PAYBACK',
    'SMS_ADAPTER_ACTIVE',
    'TELEGRAM_ADAPTER_ACTIVE',
    'WHATSAPP_ADAPTER_ACTIVE',
    'LINE_ADAPTER_ACTIVE',
    'KAKAO_ADAPTER_ACTIVE',
    'VOICE_ADAPTER_ACTIVE'
  ]::text[];
  v_optional_codes constant text[] := ARRAY[
    'PUBLIC_WEB_ACTIVE','VERIFIED_EMAIL_ACTIVE','API_EXPORT_ACTIVE',
    'SIGNED_WEBHOOK_ACTIVE','DAILY_DIGEST_ACTIVE','WEEKLY_DIGEST_ACTIVE',
    'SMS_ADAPTER_ACTIVE','TELEGRAM_ADAPTER_ACTIVE','WHATSAPP_ADAPTER_ACTIVE',
    'LINE_ADAPTER_ACTIVE','KAKAO_ADAPTER_ACTIVE','VOICE_ADAPTER_ACTIVE'
  ]::text[];
  v_optional_caps constant text[] := ARRAY[
    'PUBLIC_WEB','VERIFIED_EMAIL','API_EXPORT','SIGNED_WEBHOOK',
    'DAILY_DIGEST','WEEKLY_DIGEST','delivery.sms','delivery.telegram',
    'delivery.whatsapp','delivery.line','delivery.kakao','delivery.voice'
  ]::text[];
  v_expected_codes text[];
  v_catalog_digest char(64);
  v_offered_set_digest char(64);
  v_item_identity_digest char(64);
  v_item_digest char(64);
  v_item_identity_members jsonb := '[]'::jsonb;
  v_item_members jsonb := '[]'::jsonb;
  v_blocker_members jsonb := '[]'::jsonb;
  v_derived_items jsonb := '[]'::jsonb;
  v_item_identity_set_digest char(64);
  v_evaluation_identity_digest char(64);
  v_item_set_digest char(64);
  v_blocker_set_digest char(64);
  v_evaluation_digest char(64);
  v_receipt_digest char(64);
  v_requirement_class text;
  v_required boolean;
  v_capability_id text;
  v_measurement_unit text;
  v_comparator text;
  v_threshold numeric(24,6);
  v_item_state text;
  v_blocker_code text;
  v_remediation_code text;
  v_has_evidence boolean;
  v_evidence_valid boolean;
  v_asserted_observed_value numeric(24,6);
  v_asserted_member_set_digest char(64);
  v_asserted_evidence_as_of timestamptz;
  v_asserted_evidence_expires_at timestamptz;
  v_authority_observed_value numeric(24,6);
  v_authority_reader_digest char(64);
  v_authority_member_set_digest char(64);
  v_authority_evidence_as_of timestamptz;
  v_authority_evidence_expires_at timestamptz;
  v_authority_status text;
  v_authority_members jsonb;
  v_authority_member_count bigint;
  v_authority_tariff ops.tariff_versions%ROWTYPE;
  v_authority_cost ops.cost_allocations%ROWTYPE;
  v_authority_invoice ops.invoice_facts%ROWTYPE;
  v_required_count integer := 0;
  v_satisfied_count integer := 0;
  v_blocked_count integer := 0;
  v_unknown_count integer := 0;
  v_state text;
  v_key_hash char(64);
  v_request_hash char(64);
  v_existing_key ops.idempotency_keys%ROWTYPE;
  v_existing_evaluation ops.sku_readiness_evaluations%ROWTYPE;
  v_audit_id uuid;
  v_outbox_id uuid;
  v_response jsonb;
  v_response_bytes bytea;
  v_response_digest char(64);
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_workflow_worker'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'SKU_READINESS_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF current_setting('transaction_isolation') <> 'serializable'
     OR (p_evaluation).idempotency_key IS NULL
     OR length(btrim((p_evaluation).idempotency_key)) NOT BETWEEN 1 AND 255
     OR (p_evaluation).deployment_id IS NULL
     OR (p_evaluation).organization_id IS NULL
     OR (p_evaluation).sku IS DISTINCT FROM
        'EVIDENCE_WORKSPACE_ORGANIZATION_V1'::ops.commercial_sku
     OR (p_evaluation).environment NOT IN (
       'development','test','staging','production'
     )
     OR (p_evaluation).readiness_stage NOT IN (
       'PILOT_ENTRY_READINESS','POST_FIRST_BILLING_CYCLE',
       'GENERAL_AVAILABILITY'
     )
     OR (p_evaluation).configuration_digest !~ '^[0-9a-f]{64}$'
     OR (p_evaluation).policy_digest !~ '^[0-9a-f]{64}$'
     OR (p_evaluation).evaluator_build_digest !~ '^[0-9a-f]{64}$'
     OR (p_evaluation).offered_optional_capability_ids IS NULL
     OR NOT ops.text_array_is_sorted_unique(
       (p_evaluation).offered_optional_capability_ids
     )
     OR NOT (p_evaluation).offered_optional_capability_ids <@ v_optional_caps
     OR (p_evaluation).evaluated_at IS NULL
     OR (p_evaluation).evidence_cutoff_at IS NULL
     OR (p_evaluation).evidence_cutoff_at>(p_evaluation).evaluated_at
     OR (p_evaluation).evaluated_at>v_now
     OR p_items IS NULL
  THEN
    RAISE EXCEPTION 'SKU_READINESS_INPUT_INVALID' USING ERRCODE='22023';
  END IF;

  v_expected_codes := CASE (p_evaluation).readiness_stage
    WHEN 'PILOT_ENTRY_READINESS'
      THEN v_all_codes[1:20]||v_all_codes[25:30]
    WHEN 'POST_FIRST_BILLING_CYCLE'
      THEN v_all_codes[1:23]||v_all_codes[25:30]
    ELSE v_all_codes
  END;
  IF cardinality(p_items) IS DISTINCT FROM cardinality(v_expected_codes)
     OR ARRAY(
       SELECT item.item_code
       FROM unnest(p_items) AS item
     ) IS DISTINCT FROM v_expected_codes
  THEN
    RAISE EXCEPTION 'SKU_READINESS_CATALOG_SET_INVALID'
      USING ERRCODE='22023';
  END IF;

  v_catalog_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_SKU_READINESS_CATALOG_V1',
      'schemaVersion',1,
      'catalogVersion','evidence-workspace-readiness.v1',
      'orderedItemCodes',v_all_codes,
      'mandatoryAllStages',v_all_codes[1:8]||v_all_codes[15:20],
      'mandatoryPostFirstBilling',v_all_codes[21:23],
      'mandatoryGeneralAvailability',v_all_codes[24:24],
      'conditionalItemCodes',v_optional_codes,
      'conditionalCapabilityIds',v_optional_caps,
      'stageVisibleItemCounts',jsonb_build_object(
        'PILOT_ENTRY_READINESS',26,
        'POST_FIRST_BILLING_CYCLE',29,
        'GENERAL_AVAILABILITY',30
      ),
      'stageMarginThresholds',jsonb_build_object(
        'PILOT_ENTRY_READINESS',0.600000::numeric,
        'POST_FIRST_BILLING_CYCLE',0.600000::numeric,
        'GENERAL_AVAILABILITY',0.700000::numeric
      )
    )
  ),'sha256'),'hex');
  v_offered_set_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_SKU_READINESS_OFFERED_CAPABILITY_SET_V1',
      'schemaVersion',1,
      'capabilityIds',(p_evaluation).offered_optional_capability_ids
    )
  ),'sha256'),'hex');

  v_key_hash := encode(extensions.digest(
    convert_to(btrim((p_evaluation).idempotency_key),'UTF8'),'sha256'
  ),'hex');
  v_request_hash := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_SKU_READINESS_REQUEST_V1',
      'schemaVersion',1,
      'evaluation',to_jsonb(p_evaluation),
      'items',to_jsonb(p_items)
    )
  ),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'ECONOMICS.RECORD_SKU_READINESS_EVALUATION.V1:'||v_key_hash,0
  ));
  SELECT * INTO v_existing_key
  FROM ops.idempotency_keys
  WHERE scope='ECONOMICS.RECORD_SKU_READINESS_EVALUATION.V1'
    AND key_hash=v_key_hash
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing_key.request_hash IS DISTINCT FROM v_request_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='40001';
    END IF;
    IF v_existing_key.response_status IS NULL
       OR v_existing_key.response_body IS NULL
       OR v_existing_key.resource_type IS DISTINCT FROM 'SKU_READINESS_EVALUATION'
    THEN
      RAISE EXCEPTION 'IDEMPOTENCY_INCOMPLETE' USING ERRCODE='55000';
    END IF;
    v_response := v_existing_key.response_body;
    v_response_bytes := ops.canonical_jsonb_v1(v_response);
    RETURN (
      (v_response->>'receiptId')::uuid,
      'SKU_READINESS_EVALUATION',
      (v_response->>'resourceId')::uuid,
      1,
      (v_response->>'resourceDigest')::char(64),
      (v_response->>'auditEventId')::uuid,
      (v_response->>'outboxId')::uuid,
      201,'application/json',v_response_bytes,
      encode(extensions.digest(v_response_bytes,'sha256'),'hex'),
      (v_response->>'receiptDigest')::char(64),
      (v_response->>'committedAt')::timestamptz,true
    )::ops.economics_mutation_receipt_v1;
  END IF;
  INSERT INTO ops.idempotency_keys(
    scope,key_hash,request_hash,resource_type,resource_id,expires_at
  ) VALUES (
    'ECONOMICS.RECORD_SKU_READINESS_EVALUATION.V1',v_key_hash,v_request_hash,
    'SKU_READINESS_EVALUATION',v_evaluation_id::text,v_now+interval '24 hours'
  );

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'SKU_READINESS:'||(p_evaluation).deployment_id::text||':'||
    (p_evaluation).organization_id::text||':'||(p_evaluation).environment||':'||
    (p_evaluation).readiness_stage,0
  ));

  FOREACH v_item IN ARRAY p_items LOOP
    v_item_ordinal := v_item_ordinal+1;
    v_item_id := gen_random_uuid();
    v_capability_id := NULL;
    -- Keep caller assertions immutable. Aggregate authorities below populate
    -- separate effective scalars so PL/pgSQL never mutates a composite input
    -- field and the persisted digest cannot accidentally depend on loop-record
    -- assignment semantics.
    v_effective_evidence_tier := v_item.evidence_tier;
    v_effective_cost_allocation_period_id :=
      v_item.cost_allocation_period_id;
    v_effective_cost_allocation_row_kind :=
      v_item.cost_allocation_row_kind;
    v_effective_cost_allocation_record_digest :=
      v_item.cost_allocation_record_digest;
    v_effective_cost_allocation_close_receipt_digest :=
      v_item.cost_allocation_close_receipt_digest;
    v_effective_evidence_member_set_digest :=
      v_item.evidence_member_set_digest;
    v_effective_evidence_as_of := v_item.evidence_as_of;
    v_effective_evidence_expires_at := v_item.evidence_expires_at;
    v_effective_observed_value := v_item.observed_value;
    IF v_item.item_code=ANY(v_optional_codes) THEN
      v_requirement_class := 'CONDITIONAL_OFFERED';
      v_capability_id := v_optional_caps[
        array_position(v_optional_codes,v_item.item_code)
      ];
      v_required := v_capability_id=ANY(
        (p_evaluation).offered_optional_capability_ids
      );
    ELSE
      v_requirement_class := 'MANDATORY';
      v_required := true;
    END IF;

    v_measurement_unit := CASE v_item.item_code
      WHEN 'P75_VARIABLE_GROSS_MARGIN' THEN 'RATIO'
      WHEN 'ACTUAL_BILLABLE_RECONCILIATION' THEN 'RATIO'
      WHEN 'ACTUAL_COST_CAPTURE' THEN 'RATIO'
      WHEN 'SUPPORT_CAPACITY' THEN 'HOURS_PER_MONTH'
      WHEN 'CAC_PAYBACK' THEN 'MONTHS'
      ELSE 'BOOLEAN'
    END;
    v_comparator := CASE v_item.item_code
      WHEN 'P75_VARIABLE_GROSS_MARGIN' THEN 'GTE'
      WHEN 'ACTUAL_BILLABLE_RECONCILIATION' THEN 'GTE'
      WHEN 'ACTUAL_COST_CAPTURE' THEN 'GTE'
      WHEN 'SUPPORT_CAPACITY' THEN 'LTE'
      WHEN 'CAC_PAYBACK' THEN 'LTE'
      ELSE 'EQ'
    END;
    v_threshold := CASE v_item.item_code
      WHEN 'P75_VARIABLE_GROSS_MARGIN' THEN
        CASE (p_evaluation).readiness_stage
          WHEN 'GENERAL_AVAILABILITY' THEN 0.700000::numeric
          ELSE 0.600000::numeric
        END
      WHEN 'ACTUAL_BILLABLE_RECONCILIATION' THEN 1.000000::numeric
      WHEN 'ACTUAL_COST_CAPTURE' THEN 0.990000::numeric
      WHEN 'SUPPORT_CAPACITY' THEN 4.000000::numeric
      WHEN 'CAC_PAYBACK' THEN 12.000000::numeric
      ELSE 1.000000::numeric
    END;
    v_asserted_observed_value := v_item.observed_value;
    v_asserted_member_set_digest := v_item.evidence_member_set_digest;
    v_asserted_evidence_as_of := v_item.evidence_as_of;
    v_asserted_evidence_expires_at := v_item.evidence_expires_at;

    IF v_item.item_code IS DISTINCT FROM v_expected_codes[v_item_ordinal]
       OR v_item.evidence_tier NOT IN (
         'PRODUCTION_LIVE','PRODUCTION_DERIVED','PRODUCTION_PREFLIGHT',
         'NON_PRODUCTION_PREFLIGHT','FIXTURE_ONLY','MISSING'
       )
       OR v_item.expected_configuration_digest IS DISTINCT FROM
          (p_evaluation).configuration_digest
       OR v_item.owner_function NOT IN (
         'PRODUCT_PDM','EDITORIAL_DUTY','DATA_ENGINEERING','SRE_ON_CALL',
         'LEGAL_PRIVACY','SALES_CS_FINANCE','INDEPENDENT_REVIEW_PUBLISHER'
       )
       OR (v_item.observed_value IS NOT NULL
           AND v_measurement_unit='RATIO'
           AND v_item.observed_value NOT BETWEEN 0 AND 1)
       OR num_nonnulls(
            v_item.activation_decision_id,
            v_item.activation_decision_version,
            v_item.activation_decision_digest
          ) NOT IN (0,3)
       OR (v_item.activation_decision_version IS NOT NULL
           AND v_item.activation_decision_version<=0)
       OR num_nonnulls(
            v_item.activation_evidence_id,
            v_item.activation_evidence_digest
          ) NOT IN (0,2)
       OR (v_item.activation_evidence_id IS NOT NULL
           AND v_item.activation_decision_id IS NULL)
       OR num_nonnulls(
            v_item.commercial_contract_period_id,
            v_item.commercial_contract_record_digest
          ) NOT IN (0,2)
       OR num_nonnulls(
            v_item.tariff_version_id,v_item.tariff_record_digest
          ) NOT IN (0,2)
       OR num_nonnulls(
            v_item.invoice_fact_id,v_item.invoice_reconciliation_digest
          ) NOT IN (0,2)
       OR num_nonnulls(
            v_item.revenue_fact_id,v_item.revenue_record_digest
          ) NOT IN (0,2)
       OR num_nonnulls(
            v_item.cost_allocation_period_id,
            v_item.cost_allocation_row_kind,
            v_item.cost_allocation_record_digest,
            v_item.cost_allocation_close_receipt_digest
          ) NOT IN (0,4)
       OR (v_item.cost_allocation_period_id IS NOT NULL
           AND v_item.cost_allocation_row_kind IS DISTINCT FROM 'PERIOD')
       OR num_nonnulls(
            v_item.outcome_fact_id,v_item.outcome_fact_digest
          ) NOT IN (0,2)
       OR num_nonnulls(
            v_item.sli_window_receipt_id,v_item.sli_id,
            v_item.sli_definition_version,v_item.sli_environment,
            v_item.sli_scope_digest,v_item.sli_window_kind,
            v_item.sli_window_sequence,v_item.sli_organization_id,
            v_item.sli_contract_period_id,v_item.sli_policy_digest,
            v_item.sli_receipt_digest
          ) NOT IN (0,11)
       OR (v_item.sli_window_receipt_id IS NOT NULL
           AND (v_item.sli_environment IS DISTINCT FROM 'PRODUCTION'
                OR v_item.sli_organization_id IS DISTINCT FROM
                   (p_evaluation).organization_id))
       OR (v_item.evidence_member_set_digest IS NOT NULL
           AND v_item.evidence_member_set_digest !~ '^[0-9a-f]{64}$')
       OR (v_item.evidence_as_of IS NULL)
          IS DISTINCT FROM (v_item.observed_value IS NULL)
       OR (v_item.evidence_expires_at IS NOT NULL
           AND (v_item.evidence_as_of IS NULL
                OR v_item.evidence_expires_at<=v_item.evidence_as_of))
    THEN
      RAISE EXCEPTION 'SKU_READINESS_ITEM_INPUT_INVALID: %',v_item.item_code
        USING ERRCODE='22023';
    END IF;

    v_has_evidence := num_nonnulls(
      v_item.activation_decision_id,v_item.activation_evidence_id,
      v_item.commercial_contract_period_id,v_item.tariff_version_id,
      v_item.invoice_fact_id,v_item.revenue_fact_id,
      v_item.cost_allocation_period_id,v_item.outcome_fact_id,
      v_item.sli_window_receipt_id,v_item.evidence_member_set_digest
    )>0;
    v_evidence_valid := true;

    IF v_item.activation_decision_id IS NOT NULL THEN
      PERFORM 1 FROM ops.capability_activation_decisions d
      WHERE d.id=v_item.activation_decision_id
        AND d.decision_version=v_item.activation_decision_version
        AND d.decision_digest=v_item.activation_decision_digest
        AND d.environment=upper((p_evaluation).environment)
        AND d.configuration_digest=(p_evaluation).configuration_digest
        AND d.legal_state='APPROVED' AND d.operational_state='ACTIVE'
        AND d.effective_at<=(p_evaluation).evaluated_at
        AND (d.expires_at IS NULL OR d.expires_at>(p_evaluation).evaluated_at)
        AND NOT EXISTS (
          SELECT 1 FROM ops.capability_activation_decisions successor
          WHERE successor.capability_id=d.capability_id
            AND successor.environment=d.environment
            AND successor.decision_version>d.decision_version
        );
      IF NOT FOUND THEN v_evidence_valid := false; END IF;
    END IF;
    IF v_item.activation_evidence_id IS NOT NULL THEN
      PERFORM 1 FROM ops.capability_activation_evidence evidence
      WHERE evidence.id=v_item.activation_evidence_id
        AND evidence.decision_id=v_item.activation_decision_id
        AND evidence.evidence_ref_digest=v_item.activation_evidence_digest
        AND evidence.evidence_state='SATISFIED'
        AND evidence.proof_tier IN (
          'PRODUCTION_LEGAL','PRODUCTION_OPERATIONAL'
        )
        AND evidence.valid_from<=(p_evaluation).evaluated_at
        AND (evidence.expires_at IS NULL
             OR evidence.expires_at>(p_evaluation).evaluated_at);
      IF NOT FOUND THEN v_evidence_valid := false; END IF;
    END IF;
    IF v_item.commercial_contract_period_id IS NOT NULL THEN
      PERFORM 1 FROM ops.commercial_contract_periods contract
      WHERE contract.id=v_item.commercial_contract_period_id
        AND contract.record_digest=v_item.commercial_contract_record_digest
        AND contract.deployment_id=(p_evaluation).deployment_id
        AND contract.organization_id=(p_evaluation).organization_id
        AND contract.sku=(p_evaluation).sku
        AND contract.status='ACTIVE'
        AND contract.state_effective_at<=(p_evaluation).evaluated_at
        AND contract.period_start<=(p_evaluation).evaluated_at::date
        AND (p_evaluation).evaluated_at::date<contract.period_end
        AND NOT EXISTS (
          SELECT 1 FROM ops.commercial_contract_periods successor
          WHERE successor.supersedes_contract_period_id=contract.id
        );
      IF NOT FOUND THEN v_evidence_valid := false; END IF;
    END IF;
    IF v_item.tariff_version_id IS NOT NULL THEN
      PERFORM 1 FROM ops.tariff_versions tariff
      WHERE tariff.id=v_item.tariff_version_id
        AND tariff.record_digest=v_item.tariff_record_digest
        AND tariff.deployment_id=(p_evaluation).deployment_id
        AND tariff.sku=(p_evaluation).sku
        -- GENERAL_AVAILABILITY readiness is the pre-promotion gate.  Requiring
        -- a GA tariff here would cycle with the tariff owner's GA prerequisite.
        AND tariff.stage='PILOT'::ops.tariff_stage
        AND tariff.effective_from<=(p_evaluation).evaluated_at::date
        AND (p_evaluation).evaluated_at::date<tariff.effective_until;
      IF NOT FOUND THEN v_evidence_valid := false; END IF;
    END IF;
    IF v_item.invoice_fact_id IS NOT NULL THEN
      PERFORM 1 FROM ops.invoice_facts invoice
      WHERE invoice.id=v_item.invoice_fact_id
        AND invoice.reconciliation_digest=v_item.invoice_reconciliation_digest
        AND invoice.deployment_id=(p_evaluation).deployment_id
        AND invoice.organization_id=(p_evaluation).organization_id
        AND invoice.sku=(p_evaluation).sku
        AND invoice.reconciled_at<=(p_evaluation).evidence_cutoff_at;
      IF NOT FOUND THEN v_evidence_valid := false; END IF;
    END IF;
    IF v_item.revenue_fact_id IS NOT NULL THEN
      PERFORM 1 FROM ops.revenue_facts revenue
      WHERE revenue.id=v_item.revenue_fact_id
        AND revenue.record_digest=v_item.revenue_record_digest
        AND revenue.deployment_id=(p_evaluation).deployment_id
        AND revenue.organization_id=(p_evaluation).organization_id
        AND revenue.sku=(p_evaluation).sku
        AND revenue.recognized_at<=(p_evaluation).evidence_cutoff_at;
      IF NOT FOUND THEN v_evidence_valid := false; END IF;
    END IF;
    IF v_item.cost_allocation_period_id IS NOT NULL THEN
      PERFORM 1 FROM ops.cost_allocations cost
      WHERE cost.id=v_item.cost_allocation_period_id
        AND cost.row_kind='PERIOD'
        AND cost.record_digest=v_item.cost_allocation_record_digest
        AND cost.close_receipt_digest=
            v_item.cost_allocation_close_receipt_digest
        AND cost.deployment_id=(p_evaluation).deployment_id
        AND EXISTS (
          SELECT 1
          FROM ops.cost_allocations line
          LEFT JOIN ops.outcome_facts outcome
            ON line.target_kind='OUTCOME_FACT'
           AND outcome.id=line.outcome_fact_id
          WHERE line.row_kind='LINE'
            AND line.period_revision_id=cost.id
            AND (
              line.target_kind='ORGANIZATION'
              AND line.organization_id=(p_evaluation).organization_id
              OR line.target_kind='OUTCOME_FACT'
              AND outcome.organization_id=(p_evaluation).organization_id
            )
        );
      IF NOT FOUND THEN v_evidence_valid := false; END IF;
    END IF;
    IF v_item.outcome_fact_id IS NOT NULL THEN
      PERFORM 1 FROM ops.outcome_facts outcome
      WHERE outcome.id=v_item.outcome_fact_id
        AND outcome.fact_digest=v_item.outcome_fact_digest
        AND outcome.deployment_id=(p_evaluation).deployment_id
        AND outcome.organization_id=(p_evaluation).organization_id
        AND outcome.fact_effect<>'INVERSE'
        AND outcome.recorded_at<=(p_evaluation).evidence_cutoff_at
        AND NOT EXISTS (
          SELECT 1 FROM ops.outcome_facts successor
          WHERE successor.supersedes_fact_id=outcome.id
        )
        AND (v_item.item_code<>'FIRST_PAID_VERIFIED_WORKFLOW_CYCLE'
             OR (outcome.fact_contract_version=2
                 AND outcome.paid_packet_id IS NOT NULL));
      IF NOT FOUND THEN v_evidence_valid := false; END IF;
    END IF;
    IF v_item.sli_window_receipt_id IS NOT NULL THEN
      PERFORM 1 FROM ops.sli_window_receipts sli
      JOIN ops.commercial_contract_periods contract
        ON contract.id=v_item.sli_contract_period_id
       AND contract.organization_id=v_item.sli_organization_id
       AND contract.sla_policy_digest=v_item.sli_policy_digest
      WHERE sli.id=v_item.sli_window_receipt_id
        AND sli.sli_id=v_item.sli_id
        AND sli.definition_version=v_item.sli_definition_version
        AND sli.environment=v_item.sli_environment
        AND sli.scope_digest=v_item.sli_scope_digest
        AND sli.window_kind=v_item.sli_window_kind
        AND sli.window_sequence=v_item.sli_window_sequence
        AND sli.receipt_digest=v_item.sli_receipt_digest
        AND sli.policy_digest=v_item.sli_policy_digest
        AND sli.evaluated_at<=(p_evaluation).evidence_cutoff_at
        AND contract.deployment_id=(p_evaluation).deployment_id
        AND contract.organization_id=(p_evaluation).organization_id;
      IF NOT FOUND THEN v_evidence_valid := false; END IF;
    END IF;

    -- Aggregate readiness measurements are assertions, never caller-owned
    -- facts.  Re-read each closed authority, derive the numeric value, and hash
    -- a sorted member set.  Supplied values/digests are accepted only when they
    -- exactly match the derived authority.
    v_authority_observed_value := NULL;
    v_authority_reader_digest := NULL;
    v_authority_member_set_digest := NULL;
    v_authority_evidence_as_of := NULL;
    v_authority_evidence_expires_at := NULL;
    v_authority_status := NULL;
    v_authority_members := NULL;
    v_authority_member_count := 0;

    IF v_item.item_code='P75_VARIABLE_GROSS_MARGIN' THEN
      SELECT tariff.* INTO v_authority_tariff
      FROM ops.tariff_versions AS tariff
      WHERE tariff.id=v_item.tariff_version_id
        AND tariff.record_digest=v_item.tariff_record_digest
        AND tariff.deployment_id=(p_evaluation).deployment_id
        AND tariff.sku=(p_evaluation).sku
        AND tariff.stage='PILOT'::ops.tariff_stage
        AND tariff.effective_from<=(p_evaluation).evaluated_at::date
        AND (p_evaluation).evaluated_at::date<tariff.effective_until
        AND NOT EXISTS (
          SELECT 1 FROM ops.tariff_versions AS later
          WHERE later.deployment_id=tariff.deployment_id
            AND later.sku=tariff.sku
            AND later.effective_from>tariff.effective_from
            AND later.effective_from<=(p_evaluation).evaluated_at::date
        );
      v_evidence_valid := FOUND;
      IF v_evidence_valid THEN
        SELECT cost.* INTO v_authority_cost
        FROM ops.cost_allocations AS cost
        WHERE cost.id=v_authority_tariff.cost_allocation_period_id
          AND cost.row_kind='PERIOD'
          AND cost.record_digest=
              v_authority_tariff.cost_allocation_record_digest
          AND cost.allocation_set_digest=
              v_authority_tariff.cost_allocation_set_digest
          AND cost.close_receipt_digest=
              v_authority_tariff.cost_allocation_close_receipt_digest
          AND cost.deployment_id=(p_evaluation).deployment_id
          AND cost.closed_at<=(p_evaluation).evidence_cutoff_at
          AND NOT EXISTS (
            SELECT 1 FROM ops.cost_allocations AS successor
            WHERE successor.row_kind='PERIOD'
              AND successor.supersedes_period_revision_id=cost.id
          );
        v_evidence_valid := FOUND;
      END IF;
      IF v_evidence_valid THEN
        v_evidence_valid :=
          v_authority_tariff.margin_evidence_as_of<=
            (p_evaluation).evidence_cutoff_at
          AND v_authority_tariff.projected_p75_variable_gross_margin_basis_points=
            ops.round_half_even_numeric_v1((
              (v_authority_tariff.p75_revenue_amount-
               v_authority_tariff.p75_variable_cost_amount)
              /v_authority_tariff.p75_revenue_amount
            )*10000,0)::integer
          AND v_authority_tariff.cost_capture_coverage=
              v_authority_cost.cost_capture_coverage
          AND v_authority_tariff.direct_cost_coverage=
              v_authority_cost.direct_coverage
          AND v_authority_tariff.total_cost_coverage=
              v_authority_cost.total_coverage;
      END IF;
      IF v_evidence_valid THEN
        SELECT jsonb_agg(jsonb_build_object(
                 'memberKind',member_kind,'memberId',member_id,
                 'memberDigest',member_digest
               ) ORDER BY member_kind,member_id,member_digest)
          INTO v_authority_members
        FROM (VALUES
          ('ALLOCATION_SET',v_authority_cost.id::text,
            btrim(v_authority_cost.allocation_set_digest::text)),
          ('COST_ALLOCATION_PERIOD',v_authority_cost.id::text,
            btrim(v_authority_cost.record_digest::text)),
          ('COST_CLOSE_RECEIPT',v_authority_cost.close_receipt_id::text,
            btrim(v_authority_cost.close_receipt_digest::text)),
          ('COST_CORRECTION_SET',v_authority_cost.id::text,
            btrim(v_authority_cost.correction_set_digest::text)),
          ('COST_DRIVER_SET',v_authority_cost.id::text,
            btrim(v_authority_cost.driver_set_digest::text)),
          ('COST_POOL_SET',v_authority_cost.id::text,
            btrim(v_authority_cost.pool_set_digest::text)),
          ('COST_SOURCE_SET',v_authority_cost.id::text,
            btrim(v_authority_cost.source_set_digest::text)),
          ('MARGIN_FORMULA',v_authority_tariff.id::text,
            btrim(v_authority_tariff.margin_formula_digest::text)),
          ('P75_ASSUMPTION',v_authority_tariff.id::text,
            btrim(v_authority_tariff.p75_assumption_digest::text)),
          ('TARIFF_VERSION',v_authority_tariff.id::text,
            btrim(v_authority_tariff.record_digest::text))
        ) AS member(member_kind,member_id,member_digest);
        v_authority_observed_value := (
          v_authority_tariff.projected_p75_variable_gross_margin_basis_points
          ::numeric/10000
        )::numeric(24,6);
        v_authority_evidence_as_of :=
          v_authority_tariff.margin_evidence_as_of;
        v_authority_evidence_expires_at :=
          v_authority_tariff.effective_until::timestamp
          AT TIME ZONE v_authority_tariff.accounting_timezone;
        v_authority_status := 'KNOWN';
        v_effective_cost_allocation_period_id := v_authority_cost.id;
        v_effective_cost_allocation_row_kind := 'PERIOD';
        v_effective_cost_allocation_record_digest :=
          v_authority_cost.record_digest;
        v_effective_cost_allocation_close_receipt_digest :=
          v_authority_cost.close_receipt_digest;
      ELSE
        v_authority_status := 'UNKNOWN';
      END IF;

    ELSIF v_item.item_code='ACTUAL_BILLABLE_RECONCILIATION' THEN
      SELECT invoice.* INTO v_authority_invoice
      FROM ops.invoice_facts AS invoice
      WHERE invoice.id=v_item.invoice_fact_id
        AND invoice.reconciliation_digest=
            v_item.invoice_reconciliation_digest
        AND invoice.deployment_id=(p_evaluation).deployment_id
        AND invoice.organization_id=(p_evaluation).organization_id
        AND invoice.sku=(p_evaluation).sku
        AND invoice.reconciled_at<=(p_evaluation).evidence_cutoff_at
        AND NOT EXISTS (
          SELECT 1 FROM ops.invoice_facts AS successor
          WHERE successor.supersedes_invoice_id=invoice.id
        );
      v_evidence_valid := FOUND;
      IF v_evidence_valid THEN
        SELECT count(*) INTO v_authority_member_count
        FROM ops.invoice_usage_memberships AS membership
        WHERE membership.invoice_id=v_authority_invoice.id
          AND NOT EXISTS (
            SELECT 1 FROM ops.invoice_usage_memberships AS successor
            WHERE successor.supersedes_membership_id=membership.id
          );
        WITH members(member_kind,member_id,member_digest) AS (
          SELECT 'INVOICE_FACT',v_authority_invoice.id::text,
                 btrim(v_authority_invoice.reconciliation_digest::text)
          UNION ALL SELECT 'INVOICE_USAGE_FACT_SET',
                 v_authority_invoice.id::text,
                 btrim(v_authority_invoice.usage_fact_set_digest::text)
          UNION ALL SELECT 'INVOICE_USAGE_MEMBERSHIP_SET',
                 v_authority_invoice.id::text,
                 btrim(v_authority_invoice.usage_membership_set_digest::text)
          UNION ALL SELECT 'INVOICE_USAGE_WINDOW_RECEIPT_SET',
                 v_authority_invoice.id::text,
                 btrim(
                   v_authority_invoice.usage_window_receipt_set_digest::text
                 )
          UNION ALL
          SELECT 'USAGE_MEMBERSHIP',membership.id::text,
                 btrim(membership.membership_digest::text)
          FROM ops.invoice_usage_memberships AS membership
          WHERE membership.invoice_id=v_authority_invoice.id
            AND NOT EXISTS (
              SELECT 1 FROM ops.invoice_usage_memberships AS successor
              WHERE successor.supersedes_membership_id=membership.id
            )
        )
        SELECT jsonb_agg(jsonb_build_object(
                 'memberKind',member_kind,'memberId',member_id,
                 'memberDigest',member_digest
               ) ORDER BY member_kind,member_id,member_digest)
          INTO v_authority_members
        FROM members;
        v_authority_observed_value :=
          ops.round_half_even_numeric_v1(
            v_authority_member_count::numeric/
              v_authority_invoice.expected_usage_membership_count::numeric,
            6
          )::numeric(24,6);
        v_authority_evidence_as_of := v_authority_invoice.reconciled_at;
        v_authority_status := 'KNOWN';
      ELSE
        v_authority_status := 'UNKNOWN';
      END IF;

    ELSIF v_item.item_code='ACTUAL_COST_CAPTURE' THEN
      SELECT cost.* INTO v_authority_cost
      FROM ops.cost_allocations AS cost
      WHERE cost.id=v_item.cost_allocation_period_id
        AND cost.row_kind='PERIOD'
        AND cost.record_digest=v_item.cost_allocation_record_digest
        AND cost.close_receipt_digest=
            v_item.cost_allocation_close_receipt_digest
        AND cost.deployment_id=(p_evaluation).deployment_id
        AND cost.closed_at<=(p_evaluation).evidence_cutoff_at
        AND NOT EXISTS (
          SELECT 1 FROM ops.cost_allocations AS successor
          WHERE successor.row_kind='PERIOD'
            AND successor.supersedes_period_revision_id=cost.id
        );
      v_evidence_valid := FOUND;
      IF v_evidence_valid THEN
        SELECT count(*) INTO v_authority_member_count
        FROM ops.cost_allocations AS line
        LEFT JOIN ops.outcome_facts AS outcome
          ON line.target_kind='OUTCOME_FACT' AND outcome.id=line.outcome_fact_id
        WHERE line.row_kind='LINE'
          AND line.period_revision_id=v_authority_cost.id
          AND (
            line.target_kind='ORGANIZATION'
            AND line.organization_id=(p_evaluation).organization_id
            OR line.target_kind='OUTCOME_FACT'
            AND outcome.organization_id=(p_evaluation).organization_id
          );
        v_evidence_valid := v_authority_member_count>0;
      END IF;
      IF v_evidence_valid THEN
        WITH members(member_kind,member_id,member_digest) AS (
          SELECT 'ALLOCATION_SET',v_authority_cost.id::text,
                 btrim(v_authority_cost.allocation_set_digest::text)
          UNION ALL SELECT 'COST_ALLOCATION_PERIOD',
                 v_authority_cost.id::text,
                 btrim(v_authority_cost.record_digest::text)
          UNION ALL SELECT 'COST_CLOSE_RECEIPT',
                 v_authority_cost.close_receipt_id::text,
                 btrim(v_authority_cost.close_receipt_digest::text)
          UNION ALL SELECT 'COST_SOURCE_SET',v_authority_cost.id::text,
                 btrim(v_authority_cost.source_set_digest::text)
          UNION ALL
          SELECT 'ORGANIZATION_COST_LINE',line.id::text,
                 btrim(line.record_digest::text)
          FROM ops.cost_allocations AS line
          LEFT JOIN ops.outcome_facts AS outcome
            ON line.target_kind='OUTCOME_FACT'
           AND outcome.id=line.outcome_fact_id
          WHERE line.row_kind='LINE'
            AND line.period_revision_id=v_authority_cost.id
            AND (
              line.target_kind='ORGANIZATION'
              AND line.organization_id=(p_evaluation).organization_id
              OR line.target_kind='OUTCOME_FACT'
              AND outcome.organization_id=(p_evaluation).organization_id
            )
        )
        SELECT jsonb_agg(jsonb_build_object(
                 'memberKind',member_kind,'memberId',member_id,
                 'memberDigest',member_digest
               ) ORDER BY member_kind,member_id,member_digest)
          INTO v_authority_members
        FROM members;
        IF v_authority_cost.cost_capture_state='MEASURED'
           AND v_authority_cost.expected_cost_count IS NOT NULL THEN
          v_authority_observed_value := ops.round_half_even_numeric_v1(
            CASE WHEN v_authority_cost.expected_cost_count=0 THEN 1
              ELSE v_authority_cost.captured_cost_count::numeric/
                v_authority_cost.expected_cost_count::numeric END,
            6
          )::numeric(24,6);
          v_authority_status := 'KNOWN';
        ELSE
          v_authority_status := 'UNKNOWN';
        END IF;
        v_authority_evidence_as_of := v_authority_cost.closed_at;
      ELSE
        v_authority_status := 'UNKNOWN';
      END IF;

    ELSIF v_item.item_code='SUPPORT_CAPACITY' THEN
      SELECT authority.metric_status,authority.observed_value,
             authority.source_input_digest,authority.evidence_as_of
        INTO v_authority_status,v_authority_observed_value,
             v_authority_reader_digest,v_authority_evidence_as_of
      FROM ops.read_sku_readiness_metric_authority_v1(
        (p_evaluation).deployment_id,(p_evaluation).organization_id,
        (p_evaluation).evaluated_at,
        'BM-SUPPORT-HOURS-PER-ACTIVATED-ORG'
      ) AS authority;
      WITH current_contracts AS (
        SELECT contract.*
        FROM ops.commercial_contract_periods AS contract
        WHERE contract.deployment_id=(p_evaluation).deployment_id
          AND contract.organization_id=(p_evaluation).organization_id
          AND contract.sku=(p_evaluation).sku
          AND contract.status='ACTIVE'
          AND contract.provisioning_state='PROVISIONED'
          AND contract.state_effective_at<=(p_evaluation).evaluated_at
          AND contract.period_start<=(p_evaluation).evaluated_at::date
          AND (p_evaluation).evaluated_at::date<contract.period_end
          AND NOT EXISTS (
            SELECT 1 FROM ops.commercial_contract_periods AS successor
            WHERE successor.supersedes_contract_period_id=contract.id
          )
      ), bounds AS (
        SELECT date_trunc('month',
                 (p_evaluation).evaluated_at AT TIME ZONE
                 COALESCE(min(accounting_timezone),'UTC')
               )::date AS month_start
        FROM current_contracts
      ), period_heads AS (
        SELECT cost.*
        FROM ops.cost_allocations AS cost CROSS JOIN bounds
        WHERE cost.row_kind='PERIOD'
          AND cost.deployment_id=(p_evaluation).deployment_id
          AND cost.period_start<bounds.month_start
          AND cost.period_end>bounds.month_start-interval '2 months'
          AND cost.closed_at<=(p_evaluation).evaluated_at
          AND NOT EXISTS (
            SELECT 1 FROM ops.cost_allocations AS successor
            WHERE successor.row_kind='PERIOD'
              AND successor.supersedes_period_revision_id=cost.id
          )
      ), members(member_kind,member_id,member_digest) AS (
        SELECT 'COMMERCIAL_ELIGIBILITY_INPUT_SET','support',
               btrim(v_authority_reader_digest::text)
        UNION ALL
        SELECT 'CURRENT_CONTRACT_PERIOD',contract.id::text,
               btrim(contract.record_digest::text)
        FROM current_contracts AS contract
        UNION ALL
        SELECT 'SUPPORT_COST_PERIOD',period.id::text,
               btrim(period.record_digest::text)
        FROM period_heads AS period
        UNION ALL
        SELECT 'SUPPORT_COST_LINE',line.id::text,
               btrim(line.record_digest::text)
        FROM ops.cost_allocations AS line
        JOIN period_heads AS period ON period.id=line.period_revision_id
        WHERE line.row_kind='LINE'
          AND line.organization_id=(p_evaluation).organization_id
          AND line.driver_kind IN (
            'SUPPORT_HOUR','MATERIAL_CORRECTION_HOUR'
          )
      )
      SELECT jsonb_agg(jsonb_build_object(
               'memberKind',member_kind,'memberId',member_id,
               'memberDigest',member_digest
             ) ORDER BY member_kind,member_id,member_digest),count(*)
        INTO v_authority_members,v_authority_member_count
      FROM members;
      v_evidence_valid := v_authority_status<>'KNOWN'
        OR v_authority_member_count>1;

    ELSIF v_item.item_code='CAC_PAYBACK' THEN
      SELECT authority.metric_status,authority.observed_value,
             authority.source_input_digest,authority.evidence_as_of
        INTO v_authority_status,v_authority_observed_value,
             v_authority_reader_digest,v_authority_evidence_as_of
      FROM ops.read_sku_readiness_metric_authority_v1(
        (p_evaluation).deployment_id,(p_evaluation).organization_id,
        (p_evaluation).evaluated_at,'BM-CAC-PAYBACK-MONTHS'
      ) AS authority;
      WITH settings AS (
        SELECT COALESCE(min(contract.accounting_timezone),'UTC') AS timezone
        FROM ops.commercial_contract_periods AS contract
        WHERE contract.deployment_id=(p_evaluation).deployment_id
          AND contract.organization_id=(p_evaluation).organization_id
          AND contract.state_effective_at<=(p_evaluation).evaluated_at
      ), bounds AS (
        SELECT ((p_evaluation).evaluated_at AT TIME ZONE timezone)::date AS end_date,
               ((p_evaluation).evaluated_at AT TIME ZONE timezone)::date-90
                 AS start_date
        FROM settings
      ), policy AS (
        SELECT CASE WHEN count(DISTINCT line.accounting_policy_digest)=1
                    THEN min(line.accounting_policy_digest)::char(64) END
                 AS digest
        FROM ops.cost_allocations AS line CROSS JOIN bounds
        WHERE line.row_kind='LINE'
          AND line.cost_category='SALES_CUSTOMER_ACQUISITION'
          AND line.deployment_id=(p_evaluation).deployment_id
          AND line.period_start<bounds.end_date
          AND line.period_end>bounds.start_date
          AND line.currency='KRW'
      ), invoice_heads AS (
        SELECT invoice.*
        FROM ops.invoice_facts AS invoice CROSS JOIN bounds
        WHERE invoice.deployment_id=(p_evaluation).deployment_id
          AND invoice.organization_id=(p_evaluation).organization_id
          AND invoice.billing_cutoff_at<=(p_evaluation).evaluated_at
          AND invoice.period_start<bounds.end_date
          AND invoice.period_end>bounds.start_date
          AND NOT EXISTS (
            SELECT 1 FROM ops.invoice_facts AS successor
            WHERE successor.supersedes_invoice_id=invoice.id
          )
      ), cost_heads AS (
        SELECT cost.*
        FROM ops.cost_allocations AS cost CROSS JOIN bounds
        WHERE cost.row_kind='PERIOD'
          AND cost.deployment_id=(p_evaluation).deployment_id
          AND cost.period_start<bounds.end_date
          AND cost.period_end>bounds.start_date
          AND cost.closed_at<=(p_evaluation).evaluated_at
          AND NOT EXISTS (
            SELECT 1 FROM ops.cost_allocations AS successor
            WHERE successor.row_kind='PERIOD'
              AND successor.supersedes_period_revision_id=cost.id
          )
          AND EXISTS (
            SELECT 1 FROM ops.cost_allocations AS line
            WHERE line.row_kind='LINE'
              AND line.period_revision_id=cost.id
              AND line.organization_id=(p_evaluation).organization_id
          )
      ), members(member_kind,member_id,member_digest) AS (
        SELECT 'BUSINESS_HEALTH_INPUT_SET','cac-payback',
               btrim(v_authority_reader_digest::text)
        UNION ALL
        SELECT DISTINCT 'CAC_READER_INPUT_SET','cac-reader',
               btrim(input.input_set_digest::text)
        FROM bounds CROSS JOIN policy
        CROSS JOIN LATERAL ops.read_cac_metric_inputs_v1(
          bounds.start_date,bounds.end_date,'KRW',policy.digest
        ) AS input
        WHERE input.organization_id=(p_evaluation).organization_id
        UNION ALL
        SELECT 'ACQUISITION_COST_LINE',line.id::text,
               btrim(line.record_digest::text)
        FROM ops.cost_allocations AS line CROSS JOIN bounds
        WHERE line.row_kind='LINE'
          AND line.cost_category='SALES_CUSTOMER_ACQUISITION'
          AND line.deployment_id=(p_evaluation).deployment_id
          AND line.organization_id=(p_evaluation).organization_id
          AND line.period_start<bounds.end_date
          AND line.period_end>bounds.start_date
        UNION ALL
        SELECT 'CURRENT_INVOICE_HEAD',invoice.id::text,
               btrim(invoice.reconciliation_digest::text)
        FROM invoice_heads AS invoice
        UNION ALL
        SELECT 'REVENUE_FACT',revenue.id::text,
               btrim(revenue.record_digest::text)
        FROM ops.revenue_facts AS revenue
        JOIN invoice_heads AS invoice ON invoice.id=revenue.invoice_id
        WHERE revenue.recognized_at<=(p_evaluation).evaluated_at
        UNION ALL
        SELECT 'CURRENT_COST_PERIOD',cost.id::text,
               btrim(cost.record_digest::text)
        FROM cost_heads AS cost
      )
      SELECT jsonb_agg(jsonb_build_object(
               'memberKind',member_kind,'memberId',member_id,
               'memberDigest',member_digest
             ) ORDER BY member_kind,member_id,member_digest),count(*)
        INTO v_authority_members,v_authority_member_count
      FROM members;
      v_evidence_valid := v_authority_status<>'KNOWN'
        OR v_authority_member_count>4;
    END IF;

    IF v_item.item_code IN (
      'P75_VARIABLE_GROSS_MARGIN','ACTUAL_BILLABLE_RECONCILIATION',
      'ACTUAL_COST_CAPTURE','SUPPORT_CAPACITY','CAC_PAYBACK'
    ) THEN
      IF v_authority_members IS NOT NULL THEN
        v_authority_member_set_digest := encode(extensions.digest(
          ops.canonical_jsonb_v1(jsonb_build_object(
            'domain',CASE v_item.item_code
              WHEN 'P75_VARIABLE_GROSS_MARGIN'
                THEN 'GURINE_SKU_READINESS_P75_MARGIN_SOURCE_SET_V1'
              WHEN 'ACTUAL_BILLABLE_RECONCILIATION'
                THEN 'GURINE_SKU_READINESS_BILLABLE_SOURCE_SET_V1'
              WHEN 'ACTUAL_COST_CAPTURE'
                THEN 'GURINE_SKU_READINESS_COST_CAPTURE_SOURCE_SET_V1'
              WHEN 'SUPPORT_CAPACITY'
                THEN 'GURINE_SKU_READINESS_SUPPORT_SOURCE_SET_V1'
              ELSE 'GURINE_SKU_READINESS_CAC_PAYBACK_SOURCE_SET_V1'
            END,
            'schemaVersion',1,
            'members',v_authority_members
          )),'sha256'
        ),'hex');
      END IF;
      IF v_authority_observed_value IS NOT NULL AND (
           v_asserted_observed_value IS NOT NULL
           AND v_asserted_observed_value IS DISTINCT FROM
               v_authority_observed_value
           OR v_asserted_member_set_digest IS NOT NULL
           AND v_asserted_member_set_digest IS DISTINCT FROM
               v_authority_member_set_digest
           OR v_asserted_evidence_as_of IS NOT NULL
           AND v_asserted_evidence_as_of IS DISTINCT FROM
               v_authority_evidence_as_of
           OR v_asserted_evidence_expires_at IS NOT NULL
           AND v_asserted_evidence_expires_at IS DISTINCT FROM
               v_authority_evidence_expires_at
         )
      THEN
        RAISE EXCEPTION 'SKU_READINESS_AUTHORITY_ASSERTION_MISMATCH: %',
          v_item.item_code USING ERRCODE='22023';
      END IF;
      v_effective_observed_value := v_authority_observed_value;
      v_effective_evidence_member_set_digest :=
        v_authority_member_set_digest;
      v_effective_evidence_as_of := v_authority_evidence_as_of;
      v_effective_evidence_expires_at := v_authority_evidence_expires_at;
      v_effective_evidence_tier := CASE WHEN v_authority_status='KNOWN'
        THEN 'PRODUCTION_DERIVED' ELSE 'MISSING' END;
    END IF;

    IF v_item.item_code='CURRENT_CONTRACT_PERIOD'
       AND v_item.commercial_contract_period_id IS NULL
       OR v_item.item_code='CURRENT_TARIFF_VERSION'
          AND v_item.tariff_version_id IS NULL
       OR v_item.item_code='ACTUAL_BILLABLE_RECONCILIATION'
          AND v_item.invoice_fact_id IS NULL
       OR v_item.item_code='ACTUAL_COST_CAPTURE'
          AND v_effective_cost_allocation_period_id IS NULL
       OR v_item.item_code='FIRST_PAID_VERIFIED_WORKFLOW_CYCLE'
          AND v_item.outcome_fact_id IS NULL
    THEN
      v_evidence_valid := false;
    END IF;

    IF NOT v_required THEN
      v_item_state := 'NOT_APPLICABLE';
      v_blocker_code := NULL;
      v_remediation_code := NULL;
    ELSIF NOT v_has_evidence OR v_effective_observed_value IS NULL
          OR v_effective_evidence_as_of IS NULL THEN
      v_item_state := 'UNKNOWN';
      v_blocker_code := 'EVIDENCE_MISSING';
      v_remediation_code := 'RECORD_CURRENT_EVIDENCE';
    ELSIF NOT v_evidence_valid THEN
      v_item_state := 'UNSATISFIED';
      v_blocker_code := 'EVIDENCE_STALE';
      v_remediation_code := 'RECORD_CURRENT_EVIDENCE';
    ELSIF v_effective_evidence_tier IN (
      'MISSING','FIXTURE_ONLY','NON_PRODUCTION_PREFLIGHT'
    ) OR (v_effective_evidence_tier='PRODUCTION_PREFLIGHT'
          AND v_item.item_code NOT IN (
            'PAID_WORKSPACE_PROCESSING_ACTIVE','DEPLOYMENT_ISOLATION_PROVEN',
            'OIDC_AND_ROSTER_READY','DATA_STORES_KEYS_QUEUES_ISOLATED',
            'SOURCE_RIGHTS_CONFIGURED','TELEMETRY_ALERTS_RUNBOOK_READY',
            'BACKUP_RESTORE_PROVEN','INCIDENT_OWNERSHIP_READY',
            'BILLING_RECONCILIATION_PATH_READY','COST_CAPTURE_PATH_READY',
            'PUBLIC_WEB_ACTIVE','VERIFIED_EMAIL_ACTIVE','API_EXPORT_ACTIVE',
            'SIGNED_WEBHOOK_ACTIVE','DAILY_DIGEST_ACTIVE',
            'WEEKLY_DIGEST_ACTIVE','SMS_ADAPTER_ACTIVE',
            'TELEGRAM_ADAPTER_ACTIVE','WHATSAPP_ADAPTER_ACTIVE',
            'LINE_ADAPTER_ACTIVE','KAKAO_ADAPTER_ACTIVE',
            'VOICE_ADAPTER_ACTIVE'
          )) THEN
      v_item_state := 'UNSATISFIED';
      v_blocker_code := 'EVIDENCE_NOT_PRODUCTION_GRADE';
      v_remediation_code := 'RECORD_CURRENT_EVIDENCE';
    ELSIF v_effective_evidence_as_of>(p_evaluation).evidence_cutoff_at
          OR (v_effective_evidence_expires_at IS NOT NULL
              AND v_effective_evidence_expires_at<=
                  (p_evaluation).evaluated_at) THEN
      v_item_state := 'UNSATISFIED';
      v_blocker_code := 'EVIDENCE_STALE';
      v_remediation_code := 'RECORD_CURRENT_EVIDENCE';
    ELSIF (CASE v_comparator
      WHEN 'EQ' THEN v_effective_observed_value=v_threshold
      WHEN 'GTE' THEN v_effective_observed_value>=v_threshold
      ELSE v_effective_observed_value<=v_threshold
    END) THEN
      v_item_state := 'SATISFIED';
      v_blocker_code := NULL;
      v_remediation_code := NULL;
    ELSE
      v_item_state := 'UNSATISFIED';
      v_blocker_code := CASE v_item.item_code
        WHEN 'CURRENT_CONTRACT_PERIOD' THEN 'CONTRACT_NOT_CURRENT'
        WHEN 'CURRENT_TARIFF_VERSION' THEN 'TARIFF_NOT_CURRENT'
        WHEN 'ACTUAL_BILLABLE_RECONCILIATION'
          THEN 'RECONCILIATION_COVERAGE_BELOW_TARGET'
        WHEN 'ACTUAL_COST_CAPTURE' THEN 'COST_CAPTURE_BELOW_TARGET'
        WHEN 'P75_VARIABLE_GROSS_MARGIN' THEN 'MARGIN_BELOW_TARGET'
        WHEN 'SUPPORT_CAPACITY' THEN 'SUPPORT_CAPACITY_ABOVE_TARGET'
        WHEN 'FIRST_PAID_VERIFIED_WORKFLOW_CYCLE'
          THEN 'VERIFIED_WORKFLOW_CYCLE_MISSING'
        WHEN 'CAC_PAYBACK' THEN 'CAC_PAYBACK_ABOVE_TARGET'
        ELSE 'CAPABILITY_NOT_ACTIVE'
      END;
      v_remediation_code := CASE v_item.item_code
        WHEN 'CURRENT_CONTRACT_PERIOD' THEN 'ACTIVATE_COMMERCIAL_CONTRACT'
        WHEN 'CURRENT_TARIFF_VERSION' THEN 'ACTIVATE_TARIFF_VERSION'
        WHEN 'ACTUAL_BILLABLE_RECONCILIATION'
          THEN 'RECONCILE_BILLABLE_FACTS'
        WHEN 'ACTUAL_COST_CAPTURE' THEN 'CLOSE_COST_ALLOCATION_PERIOD'
        WHEN 'P75_VARIABLE_GROSS_MARGIN'
          THEN 'ADJUST_PRICE_QUOTA_OR_EFFICIENCY'
        WHEN 'SUPPORT_CAPACITY' THEN 'RESTORE_SUPPORT_CAPACITY'
        WHEN 'FIRST_PAID_VERIFIED_WORKFLOW_CYCLE'
          THEN 'RECORD_FIRST_VERIFIED_WORKFLOW'
        WHEN 'CAC_PAYBACK' THEN 'ADJUST_PRICE_QUOTA_OR_EFFICIENCY'
        ELSE 'COMPLETE_CAPABILITY_ACTIVATION'
      END;
    END IF;

    v_item_identity_digest := encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'domain','GURINE_SKU_READINESS_ITEM_IDENTITY_V1',
        'schemaVersion',1,
        'itemCode',v_item.item_code,
        'requirementClass',v_requirement_class,
        'requiredForEvaluation',v_required,
        'evidenceTier',v_effective_evidence_tier,
        'expectedConfigurationDigest',v_item.expected_configuration_digest,
        'activationDecisionId',v_item.activation_decision_id,
        'activationDecisionVersion',v_item.activation_decision_version,
        'activationDecisionDigest',v_item.activation_decision_digest,
        'activationEvidenceId',v_item.activation_evidence_id,
        'activationEvidenceDigest',v_item.activation_evidence_digest,
        'commercialContractPeriodId',v_item.commercial_contract_period_id,
        'commercialContractRecordDigest',
          v_item.commercial_contract_record_digest,
        'tariffVersionId',v_item.tariff_version_id,
        'tariffRecordDigest',v_item.tariff_record_digest,
        'invoiceFactId',v_item.invoice_fact_id,
        'invoiceReconciliationDigest',v_item.invoice_reconciliation_digest,
        'revenueFactId',v_item.revenue_fact_id,
        'revenueRecordDigest',v_item.revenue_record_digest,
        'costAllocationPeriodId',v_effective_cost_allocation_period_id,
        'costAllocationRowKind',v_effective_cost_allocation_row_kind,
        'costAllocationRecordDigest',
          v_effective_cost_allocation_record_digest,
        'costAllocationCloseReceiptDigest',
          v_effective_cost_allocation_close_receipt_digest
      ) || jsonb_build_object(
        'outcomeFactId',v_item.outcome_fact_id,
        'outcomeFactDigest',v_item.outcome_fact_digest,
        'sliWindowReceiptId',v_item.sli_window_receipt_id,
        'sliId',v_item.sli_id,
        'sliDefinitionVersion',v_item.sli_definition_version,
        'sliEnvironment',v_item.sli_environment,
        'sliScopeDigest',v_item.sli_scope_digest,
        'sliWindowKind',v_item.sli_window_kind,
        'sliWindowSequence',v_item.sli_window_sequence,
        'sliOrganizationId',v_item.sli_organization_id,
        'sliContractPeriodId',v_item.sli_contract_period_id,
        'sliPolicyDigest',v_item.sli_policy_digest,
        'sliReceiptDigest',v_item.sli_receipt_digest,
        'evidenceMemberSetDigest',v_effective_evidence_member_set_digest,
        'evidenceAsOf',v_effective_evidence_as_of,
        'evidenceExpiresAt',v_effective_evidence_expires_at,
        'measurementUnit',v_measurement_unit,
        'comparator',v_comparator,
        'observedValue',v_effective_observed_value,
        'thresholdValue',v_threshold,
        'ownerFunction',v_item.owner_function
      )),'sha256'
    ),'hex');
    v_item_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'domain','GURINE_SKU_READINESS_ITEM_V1',
        'schemaVersion',1,
        'id',v_item_id,
        'evaluationId',v_evaluation_id,
        'itemOrdinal',v_item_ordinal,
        'itemCode',v_item.item_code,
        'itemIdentityDigest',v_item_identity_digest,
        'requirementClass',v_requirement_class,
        'requiredForEvaluation',v_required,
        'itemState',v_item_state,
        'evidenceTier',v_effective_evidence_tier,
        'expectedConfigurationDigest',v_item.expected_configuration_digest,
        'activationDecisionId',v_item.activation_decision_id,
        'activationDecisionVersion',v_item.activation_decision_version,
        'activationDecisionDigest',v_item.activation_decision_digest,
        'activationEvidenceId',v_item.activation_evidence_id,
        'activationEvidenceDigest',v_item.activation_evidence_digest,
        'commercialContractPeriodId',v_item.commercial_contract_period_id,
        'commercialContractRecordDigest',
          v_item.commercial_contract_record_digest,
        'tariffVersionId',v_item.tariff_version_id,
        'tariffRecordDigest',v_item.tariff_record_digest,
        'invoiceFactId',v_item.invoice_fact_id,
        'invoiceReconciliationDigest',v_item.invoice_reconciliation_digest,
        'revenueFactId',v_item.revenue_fact_id,
        'revenueRecordDigest',v_item.revenue_record_digest,
        'costAllocationPeriodId',v_effective_cost_allocation_period_id,
        'costAllocationRowKind',v_effective_cost_allocation_row_kind,
        'costAllocationRecordDigest',
          v_effective_cost_allocation_record_digest,
        'costAllocationCloseReceiptDigest',
          v_effective_cost_allocation_close_receipt_digest
      ) || jsonb_build_object(
        'outcomeFactId',v_item.outcome_fact_id,
        'outcomeFactDigest',v_item.outcome_fact_digest,
        'sliWindowReceiptId',v_item.sli_window_receipt_id,
        'sliId',v_item.sli_id,
        'sliDefinitionVersion',v_item.sli_definition_version,
        'sliEnvironment',v_item.sli_environment,
        'sliScopeDigest',v_item.sli_scope_digest,
        'sliWindowKind',v_item.sli_window_kind,
        'sliWindowSequence',v_item.sli_window_sequence,
        'sliOrganizationId',v_item.sli_organization_id,
        'sliContractPeriodId',v_item.sli_contract_period_id,
        'sliPolicyDigest',v_item.sli_policy_digest,
        'sliReceiptDigest',v_item.sli_receipt_digest,
        'evidenceMemberSetDigest',v_effective_evidence_member_set_digest,
        'evidenceAsOf',v_effective_evidence_as_of,
        'evidenceExpiresAt',v_effective_evidence_expires_at,
        'measurementUnit',v_measurement_unit,
        'comparator',v_comparator,
        'observedValue',v_effective_observed_value,
        'thresholdValue',v_threshold,
        'blockerCode',v_blocker_code,
        'remediationCode',v_remediation_code,
        'ownerFunction',v_item.owner_function
      )
    ),'sha256'),'hex');

    v_item_identity_members := v_item_identity_members||jsonb_build_array(
      jsonb_build_object(
        'itemCode',v_item.item_code,
        'itemIdentityDigest',v_item_identity_digest
      )
    );
    v_item_members := v_item_members||jsonb_build_array(jsonb_build_object(
      'itemOrdinal',v_item_ordinal,'itemId',v_item_id,
      'itemDigest',v_item_digest
    ));
    IF v_required AND v_item_state IN ('UNSATISFIED','UNKNOWN') THEN
      v_blocker_members := v_blocker_members||jsonb_build_array(
        jsonb_build_object(
          'itemOrdinal',v_item_ordinal,'itemId',v_item_id,
          'itemDigest',v_item_digest
        )
      );
    END IF;
    v_derived_items := v_derived_items||jsonb_build_array(jsonb_build_object(
      'id',v_item_id,
      'item_ordinal',v_item_ordinal,
      'item_code',v_item.item_code,
      'item_identity_digest',v_item_identity_digest,
      'requirement_class',v_requirement_class,
      'required_for_evaluation',v_required,
      'item_state',v_item_state,
      'evidence_tier',v_effective_evidence_tier,
      'expected_configuration_digest',v_item.expected_configuration_digest,
      'activation_decision_id',v_item.activation_decision_id,
      'activation_decision_version',v_item.activation_decision_version,
      'activation_decision_digest',v_item.activation_decision_digest,
      'activation_evidence_id',v_item.activation_evidence_id,
      'activation_evidence_digest',v_item.activation_evidence_digest,
      'commercial_contract_period_id',v_item.commercial_contract_period_id,
      'commercial_contract_record_digest',
        v_item.commercial_contract_record_digest,
      'tariff_version_id',v_item.tariff_version_id,
      'tariff_record_digest',v_item.tariff_record_digest,
      'invoice_fact_id',v_item.invoice_fact_id,
      'invoice_reconciliation_digest',v_item.invoice_reconciliation_digest,
      'revenue_fact_id',v_item.revenue_fact_id,
      'revenue_record_digest',v_item.revenue_record_digest,
      'cost_allocation_period_id',v_effective_cost_allocation_period_id,
      'cost_allocation_row_kind',v_effective_cost_allocation_row_kind,
      'cost_allocation_record_digest',
        v_effective_cost_allocation_record_digest,
      'cost_allocation_close_receipt_digest',
        v_effective_cost_allocation_close_receipt_digest,
      'outcome_fact_id',v_item.outcome_fact_id,
      'outcome_fact_digest',v_item.outcome_fact_digest,
      'sli_window_receipt_id',v_item.sli_window_receipt_id,
      'sli_id',v_item.sli_id,
      'sli_definition_version',v_item.sli_definition_version,
      'sli_environment',v_item.sli_environment,
      'sli_scope_digest',v_item.sli_scope_digest,
      'sli_window_kind',v_item.sli_window_kind,
      'sli_window_sequence',v_item.sli_window_sequence,
      'sli_organization_id',v_item.sli_organization_id,
      'sli_contract_period_id',v_item.sli_contract_period_id,
      'sli_policy_digest',v_item.sli_policy_digest,
      'sli_receipt_digest',v_item.sli_receipt_digest,
      'evidence_member_set_digest',v_effective_evidence_member_set_digest,
      'evidence_as_of',v_effective_evidence_as_of,
      'evidence_expires_at',v_effective_evidence_expires_at,
      'measurement_unit',v_measurement_unit,
      'comparator',v_comparator,
      'observed_value',v_effective_observed_value,
      'threshold_value',v_threshold,
      'blocker_code',v_blocker_code,
      'remediation_code',v_remediation_code,
      'owner_function',v_item.owner_function,
      'item_digest',v_item_digest
    ));

    IF v_required THEN
      v_required_count := v_required_count+1;
      IF v_item_state='SATISFIED' THEN
        v_satisfied_count := v_satisfied_count+1;
      ELSIF v_item_state='UNSATISFIED' THEN
        v_blocked_count := v_blocked_count+1;
      ELSE
        v_unknown_count := v_unknown_count+1;
      END IF;
    END IF;
  END LOOP;

  v_item_identity_set_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'domain','GURINE_SKU_READINESS_ITEM_IDENTITY_SET_V1',
      'schemaVersion',1,
      'members',v_item_identity_members
    )),'sha256'
  ),'hex');
  v_evaluation_identity_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'domain','GURINE_SKU_READINESS_NATURAL_IDENTITY_V1',
      'schemaVersion',1,
      'deploymentId',(p_evaluation).deployment_id,
      'organizationId',(p_evaluation).organization_id,
      'sku',(p_evaluation).sku,
      'environment',(p_evaluation).environment,
      'readinessStage',(p_evaluation).readiness_stage,
      'configurationDigest',(p_evaluation).configuration_digest,
      'catalogVersion','evidence-workspace-readiness.v1',
      'catalogDigest',v_catalog_digest,
      'policyDigest',(p_evaluation).policy_digest,
      'offeredCapabilitySetDigest',v_offered_set_digest,
      'evidenceCutoffAt',(p_evaluation).evidence_cutoff_at,
      'itemIdentitySetDigest',v_item_identity_set_digest
    )),'sha256'
  ),'hex');

  SELECT * INTO v_existing_evaluation
  FROM ops.sku_readiness_evaluations evaluation
  WHERE evaluation.deployment_id=(p_evaluation).deployment_id
    AND evaluation.organization_id=(p_evaluation).organization_id
    AND evaluation.sku=(p_evaluation).sku
    AND evaluation.environment=(p_evaluation).environment
    AND evaluation.readiness_stage=(p_evaluation).readiness_stage
    AND evaluation.evaluation_identity_digest=v_evaluation_identity_digest;
  IF FOUND THEN
    SELECT * INTO v_existing_key
    FROM ops.idempotency_keys
    WHERE scope='ECONOMICS.RECORD_SKU_READINESS_EVALUATION.V1'
      AND resource_type='SKU_READINESS_EVALUATION'
      AND resource_id=v_existing_evaluation.id::text
      AND response_status=201 AND response_body IS NOT NULL
    ORDER BY created_at,id
    LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'SKU_READINESS_REPLAY_RECEIPT_MISSING'
        USING ERRCODE='XX000';
    END IF;
    UPDATE ops.idempotency_keys SET
      response_status=v_existing_key.response_status,
      response_body=v_existing_key.response_body,
      resource_type=v_existing_key.resource_type,
      resource_id=v_existing_key.resource_id,
      expires_at=v_now+interval '24 hours'
    WHERE scope='ECONOMICS.RECORD_SKU_READINESS_EVALUATION.V1'
      AND key_hash=v_key_hash;
    v_response := v_existing_key.response_body;
    v_response_bytes := ops.canonical_jsonb_v1(v_response);
    RETURN (
      (v_response->>'receiptId')::uuid,
      'SKU_READINESS_EVALUATION',v_existing_evaluation.id,1,
      v_existing_evaluation.evaluation_digest,
      (v_response->>'auditEventId')::uuid,
      (v_response->>'outboxId')::uuid,
      201,'application/json',v_response_bytes,
      encode(extensions.digest(v_response_bytes,'sha256'),'hex'),
      v_existing_evaluation.receipt_digest,
      (v_response->>'committedAt')::timestamptz,true
    )::ops.economics_mutation_receipt_v1;
  END IF;

  v_item_set_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_SKU_READINESS_ITEM_SET_V1',
      'schemaVersion',1,
      'members',v_item_members
    )
  ),'sha256'),'hex');
  v_blocker_set_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_SKU_READINESS_BLOCKER_SET_V1',
      'schemaVersion',1,
      'members',v_blocker_members
    )
  ),'sha256'),'hex');
  v_state := CASE
    WHEN v_blocked_count>0 THEN 'BLOCKED'
    WHEN v_unknown_count>0 THEN 'UNKNOWN'
    ELSE 'READY'
  END;
  v_evaluation_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_SKU_READINESS_EVALUATION_V1',
      'schemaVersion',1,
      'id',v_evaluation_id,
      'deploymentId',(p_evaluation).deployment_id,
      'organizationId',(p_evaluation).organization_id,
      'sku',(p_evaluation).sku,
      'environment',(p_evaluation).environment,
      'readinessStage',(p_evaluation).readiness_stage,
      'configurationDigest',(p_evaluation).configuration_digest,
      'catalogVersion','evidence-workspace-readiness.v1',
      'catalogDigest',v_catalog_digest,
      'policyDigest',(p_evaluation).policy_digest,
      'offeredOptionalCapabilityIds',
        (p_evaluation).offered_optional_capability_ids,
      'offeredCapabilitySetDigest',v_offered_set_digest,
      'itemIdentitySetDigest',v_item_identity_set_digest,
      'evaluationIdentityDigest',v_evaluation_identity_digest,
      'evaluatedAt',(p_evaluation).evaluated_at,
      'evidenceCutoffAt',(p_evaluation).evidence_cutoff_at,
      'itemCount',cardinality(v_expected_codes),
      'requiredItemCount',v_required_count,
      'satisfiedRequiredItemCount',v_satisfied_count,
      'blockedRequiredItemCount',v_blocked_count,
      'unknownRequiredItemCount',v_unknown_count,
      'optionalItemCount',12,
      'itemSetDigest',v_item_set_digest,
      'blockerSetDigest',v_blocker_set_digest,
      'state',v_state,
      'evaluatorBuildDigest',(p_evaluation).evaluator_build_digest
    )
  ),'sha256'),'hex');
  v_receipt_digest := encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_ECONOMICS_MUTATION_RECEIPT_V1',
      'schemaVersion',1,
      'receiptId',v_evaluation_id,
      'resourceType','SKU_READINESS_EVALUATION',
      'resourceId',v_evaluation_id,
      'resourceVersion',1,
      'resourceDigest',v_evaluation_digest,
      'committedAt',v_now
    )
  ),'sha256'),'hex');

  INSERT INTO ops.sku_readiness_evaluations(
    id,deployment_id,organization_id,sku,environment,readiness_stage,
    configuration_digest,catalog_version,catalog_digest,policy_digest,
    offered_optional_capability_ids,offered_capability_set_digest,
    item_identity_set_digest,evaluation_identity_digest,evaluated_at,
    evidence_cutoff_at,item_count,required_item_count,
    satisfied_required_item_count,blocked_required_item_count,
    unknown_required_item_count,optional_item_count,item_set_digest,
    blocker_set_digest,state,evaluator_build_digest,evaluation_digest,
    receipt_digest,recorded_at
  ) VALUES (
    v_evaluation_id,(p_evaluation).deployment_id,
    (p_evaluation).organization_id,(p_evaluation).sku,
    (p_evaluation).environment,(p_evaluation).readiness_stage,
    (p_evaluation).configuration_digest,'evidence-workspace-readiness.v1',
    v_catalog_digest,(p_evaluation).policy_digest,
    (p_evaluation).offered_optional_capability_ids,v_offered_set_digest,
    v_item_identity_set_digest,v_evaluation_identity_digest,
    (p_evaluation).evaluated_at,(p_evaluation).evidence_cutoff_at,
    cardinality(v_expected_codes),v_required_count,v_satisfied_count,
    v_blocked_count,v_unknown_count,12,v_item_set_digest,
    v_blocker_set_digest,v_state,(p_evaluation).evaluator_build_digest,
    v_evaluation_digest,v_receipt_digest,v_now
  );

  INSERT INTO ops.sku_readiness_items(
    id,evaluation_id,item_ordinal,item_code,item_identity_digest,
    requirement_class,required_for_evaluation,item_state,evidence_tier,
    expected_configuration_digest,activation_decision_id,
    activation_decision_version,activation_decision_digest,
    activation_evidence_id,activation_evidence_digest,
    commercial_contract_period_id,commercial_contract_record_digest,
    tariff_version_id,tariff_record_digest,invoice_fact_id,
    invoice_reconciliation_digest,revenue_fact_id,revenue_record_digest,
    cost_allocation_period_id,cost_allocation_row_kind,
    cost_allocation_record_digest,cost_allocation_close_receipt_digest,
    outcome_fact_id,outcome_fact_digest,sli_window_receipt_id,sli_id,
    sli_definition_version,sli_environment,sli_scope_digest,sli_window_kind,
    sli_window_sequence,sli_organization_id,sli_contract_period_id,
    sli_policy_digest,sli_receipt_digest,evidence_member_set_digest,
    evidence_as_of,evidence_expires_at,measurement_unit,comparator,
    observed_value,threshold_value,blocker_code,remediation_code,
    owner_function,item_digest,recorded_at
  )
  SELECT
    item.id,v_evaluation_id,item.item_ordinal,item.item_code,
    item.item_identity_digest,item.requirement_class,
    item.required_for_evaluation,item.item_state,item.evidence_tier,
    item.expected_configuration_digest,item.activation_decision_id,
    item.activation_decision_version,item.activation_decision_digest,
    item.activation_evidence_id,item.activation_evidence_digest,
    item.commercial_contract_period_id,
    item.commercial_contract_record_digest,item.tariff_version_id,
    item.tariff_record_digest,item.invoice_fact_id,
    item.invoice_reconciliation_digest,item.revenue_fact_id,
    item.revenue_record_digest,item.cost_allocation_period_id,
    item.cost_allocation_row_kind,item.cost_allocation_record_digest,
    item.cost_allocation_close_receipt_digest,item.outcome_fact_id,
    item.outcome_fact_digest,item.sli_window_receipt_id,item.sli_id,
    item.sli_definition_version,item.sli_environment,item.sli_scope_digest,
    item.sli_window_kind,item.sli_window_sequence,item.sli_organization_id,
    item.sli_contract_period_id,item.sli_policy_digest,
    item.sli_receipt_digest,item.evidence_member_set_digest,
    item.evidence_as_of,item.evidence_expires_at,item.measurement_unit,
    item.comparator,item.observed_value,item.threshold_value,
    item.blocker_code,item.remediation_code,item.owner_function,
    item.item_digest,v_now
  FROM jsonb_to_recordset(v_derived_items) AS item(
    id uuid,item_ordinal integer,item_code text,item_identity_digest char(64),
    requirement_class text,required_for_evaluation boolean,item_state text,
    evidence_tier text,expected_configuration_digest char(64),
    activation_decision_id uuid,activation_decision_version bigint,
    activation_decision_digest char(64),activation_evidence_id uuid,
    activation_evidence_digest char(64),commercial_contract_period_id uuid,
    commercial_contract_record_digest char(64),tariff_version_id uuid,
    tariff_record_digest char(64),invoice_fact_id uuid,
    invoice_reconciliation_digest char(64),revenue_fact_id uuid,
    revenue_record_digest char(64),cost_allocation_period_id uuid,
    cost_allocation_row_kind text,cost_allocation_record_digest char(64),
    cost_allocation_close_receipt_digest char(64),outcome_fact_id uuid,
    outcome_fact_digest char(64),sli_window_receipt_id uuid,sli_id text,
    sli_definition_version text,sli_environment text,sli_scope_digest char(64),
    sli_window_kind text,sli_window_sequence bigint,sli_organization_id uuid,
    sli_contract_period_id uuid,sli_policy_digest char(64),
    sli_receipt_digest char(64),evidence_member_set_digest char(64),
    evidence_as_of timestamptz,evidence_expires_at timestamptz,
    measurement_unit text,comparator text,observed_value numeric(24,6),
    threshold_value numeric(24,6),blocker_code text,remediation_code text,
    owner_function text,item_digest char(64)
  );

  v_audit_id := ops.append_audit_event(
    'workflow:sku-readiness:'||v_evaluation_id::text,
    'SERVICE','workflow-worker.sku-readiness-evaluator',NULL::uuid,
    'SKU_READINESS_EVALUATION_RECORDED','SkuReadinessEvaluation',
    v_evaluation_id::text,'sku-readiness.evaluate','SUCCESS',
    'DERIVED_AUTHORITY',v_evaluation_id,
    jsonb_build_object(
      'evaluationId',v_evaluation_id,
      'evaluationDigest',v_evaluation_digest,
      'evaluationIdentityDigest',v_evaluation_identity_digest,
      'state',v_state,'itemCount',cardinality(v_expected_codes),
      'requiredItemCount',v_required_count,
      'blockedRequiredItemCount',v_blocked_count,
      'unknownRequiredItemCount',v_unknown_count,
      'receiptDigest',v_receipt_digest
    )
  );
  v_outbox_id := ops.enqueue_outbox(
    'sku_readiness_evaluation',v_evaluation_id::text,1,
    'commercial.sku_readiness_evaluated.v1',jsonb_build_object(
      'evaluationId',v_evaluation_id,
      'deploymentId',(p_evaluation).deployment_id,
      'organizationId',(p_evaluation).organization_id,
      'sku',(p_evaluation).sku,
      'environment',(p_evaluation).environment,
      'readinessStage',(p_evaluation).readiness_stage,
      'configurationDigest',(p_evaluation).configuration_digest,
      'catalogVersion','evidence-workspace-readiness.v1',
      'catalogDigest',v_catalog_digest,
      'policyDigest',(p_evaluation).policy_digest,
      'offeredCapabilitySetDigest',v_offered_set_digest,
      'itemIdentitySetDigest',v_item_identity_set_digest,
      'evaluationIdentityDigest',v_evaluation_identity_digest,
      'evaluatedAt',(p_evaluation).evaluated_at,
      'evidenceCutoffAt',(p_evaluation).evidence_cutoff_at,
      'itemCount',cardinality(v_expected_codes),
      'requiredItemCount',v_required_count,
      'satisfiedRequiredItemCount',v_satisfied_count,
      'blockedRequiredItemCount',v_blocked_count,
      'unknownRequiredItemCount',v_unknown_count,
      'itemSetDigest',v_item_set_digest,'state',v_state,
      'blockerSetDigest',v_blocker_set_digest,
      'evaluationDigest',v_evaluation_digest,
      'receiptDigest',v_receipt_digest
    ),v_now
  );
  v_response := jsonb_build_object(
    'receiptId',v_evaluation_id,
    'resourceType','SKU_READINESS_EVALUATION',
    'resourceId',v_evaluation_id,
    'resourceVersion',1,
    'resourceDigest',v_evaluation_digest,
    'auditEventId',v_audit_id,
    'outboxId',v_outbox_id,
    'receiptDigest',v_receipt_digest,
    'committedAt',v_now
  );
  v_response_bytes := ops.canonical_jsonb_v1(v_response);
  v_response_digest := encode(
    extensions.digest(v_response_bytes,'sha256'),'hex'
  );
  UPDATE ops.idempotency_keys SET
    response_status=201,response_body=v_response,
    resource_type='SKU_READINESS_EVALUATION',
    resource_id=v_evaluation_id::text,
    expires_at=v_now+interval '24 hours'
  WHERE scope='ECONOMICS.RECORD_SKU_READINESS_EVALUATION.V1'
    AND key_hash=v_key_hash AND request_hash=v_request_hash;
  RETURN (
    v_evaluation_id,'SKU_READINESS_EVALUATION',v_evaluation_id,1,
    v_evaluation_digest,v_audit_id,v_outbox_id,201,'application/json',
    v_response_bytes,v_response_digest,v_receipt_digest,v_now,false
  )::ops.economics_mutation_receipt_v1;
END
$$;
ALTER FUNCTION ops.record_sku_readiness_evaluation_v1(
  ops.sku_readiness_evaluation_input_v1,
  ops.sku_readiness_item_input_v1[]
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_sku_readiness_evaluation_v1(
  ops.sku_readiness_evaluation_input_v1,
  ops.sku_readiness_item_input_v1[]
) FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_analysis_worker,gurine_public_projector,
  gurine_public_api,gurine_submission_api,gurine_ingest_worker,
  gurine_notification_worker,gurine_scheduler,gurine_document_extractor,
  gurine_identity_api,gurine_auditor;
GRANT EXECUTE ON FUNCTION ops.record_sku_readiness_evaluation_v1(
  ops.sku_readiness_evaluation_input_v1,
  ops.sku_readiness_item_input_v1[]
) TO gurine_workflow_worker;
GRANT USAGE ON TYPE ops.sku_readiness_evaluation_input_v1,
  ops.sku_readiness_item_input_v1
TO gurine_workflow_worker;
CREATE TRIGGER sku_readiness_evaluations_r6e_immutable
  BEFORE UPDATE OR DELETE ON ops.sku_readiness_evaluations
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER sku_readiness_items_r6e_immutable
  BEFORE UPDATE OR DELETE ON ops.sku_readiness_items
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON ops.sku_readiness_evaluations,
  ops.sku_readiness_items
FROM PUBLIC,gurine_economics_importer,gurine_billing_gateway,
  gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_public_projector,gurine_public_api,gurine_submission_api,
  gurine_ingest_worker,gurine_notification_worker,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor;

-- R6E_FUNDING_DISCLOSURE_OWNER_FUNCTIONS

-- Publishing and public projection deliberately share these private digest
-- helpers.  Callers resolve and order concrete rows; the helpers own the
-- domain separator, schema version and JSON framing so the two trust
-- boundaries cannot silently drift.
CREATE FUNCTION editorial.funding_disclosure_sha256_v1(
  p_preimage jsonb
) RETURNS char(64)
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_disclosure_sha256$
BEGIN
  IF p_preimage IS NULL OR jsonb_typeof(p_preimage)<>'object' THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_DIGEST_PREIMAGE_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN encode(extensions.digest(
    ops.canonical_jsonb_v1(p_preimage),'sha256'
  ),'hex')::char(64);
END
$r6e_funding_disclosure_sha256$;
ALTER FUNCTION editorial.funding_disclosure_sha256_v1(jsonb)
  OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_conditional_gate_set_digest_v1(
  p_members jsonb
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_conditional_gate_digest$
BEGIN
  IF p_members IS NULL OR jsonb_typeof(p_members)<>'array'
     OR jsonb_array_length(p_members)>10000 THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_CONDITIONAL_GATE_SET_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_CONDITIONAL_GATE_SET_V1',
    'schemaVersion',1,'members',p_members
  ));
END
$r6e_funding_conditional_gate_digest$;
ALTER FUNCTION
  editorial.funding_disclosure_conditional_gate_set_digest_v1(jsonb)
  OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_source_entry_set_digest_v1(
  p_members jsonb
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_source_entry_set_digest$
BEGIN
  IF p_members IS NULL OR jsonb_typeof(p_members)<>'array'
     OR jsonb_array_length(p_members) NOT BETWEEN 1 AND 10000 THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_SOURCE_ENTRY_SET_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_DISCLOSURE_SOURCE_ENTRY_SET_V1',
    'schemaVersion',1,'members',p_members
  ));
END
$r6e_funding_source_entry_set_digest$;
ALTER FUNCTION editorial.funding_disclosure_source_entry_set_digest_v1(jsonb)
  OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_counterparty_group_set_digest_v1(
  p_members jsonb
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_group_set_digest$
BEGIN
  IF p_members IS NULL OR jsonb_typeof(p_members)<>'array'
     OR jsonb_array_length(p_members) NOT BETWEEN 1 AND 10000 THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_GROUP_SET_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_DISCLOSURE_COUNTERPARTY_GROUP_SET_V1',
    'schemaVersion',1,'members',p_members
  ));
END
$r6e_funding_group_set_digest$;
ALTER FUNCTION
  editorial.funding_disclosure_counterparty_group_set_digest_v1(jsonb)
  OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_independent_review_set_digest_v1(
  p_members jsonb
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_review_set_digest$
BEGIN
  IF p_members IS NULL OR jsonb_typeof(p_members)<>'array'
     OR jsonb_array_length(p_members)>10000 THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_REVIEW_SET_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_DISCLOSURE_INDEPENDENT_REVIEW_SET_V1',
    'schemaVersion',1,'members',p_members
  ));
END
$r6e_funding_review_set_digest$;
ALTER FUNCTION
  editorial.funding_disclosure_independent_review_set_digest_v1(jsonb)
  OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_source_link_set_digest_v1(
  p_links text[]
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_source_link_set_digest$
DECLARE
  v_canonical text[];
BEGIN
  IF p_links IS NULL OR cardinality(p_links) NOT BETWEEN 1 AND 10000
     OR EXISTS (
       SELECT 1 FROM unnest(p_links) AS link(value)
       WHERE link.value IS NULL OR length(link.value) NOT BETWEEN 9 AND 2048
         OR link.value NOT LIKE 'https://%'
         OR link.value~'[@[:space:]\\]'
         OR substring(link.value FROM 9)~'^[/?:#]'
     ) THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_SOURCE_LINK_SET_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT array_agg(link.value ORDER BY link.value COLLATE "C")
  INTO v_canonical
  FROM (SELECT DISTINCT value FROM unnest(p_links) AS source(value)) AS link;
  IF v_canonical IS DISTINCT FROM p_links THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_SOURCE_LINK_SET_NOT_CANONICAL'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_DISCLOSURE_SOURCE_LINK_SET_V1',
    'schemaVersion',1,'links',to_jsonb(p_links)
  ));
END
$r6e_funding_source_link_set_digest$;
ALTER FUNCTION editorial.funding_disclosure_source_link_set_digest_v1(text[])
  OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_entry_digest_v1(
  p_entry jsonb
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_entry_digest$
BEGIN
  IF p_entry IS NULL OR jsonb_typeof(p_entry)<>'object'
     OR p_entry ? 'entry_digest' OR p_entry ? 'created_at' THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_ENTRY_PREIMAGE_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_DISCLOSURE_ENTRY_V1',
    'schemaVersion',1,'entry',p_entry
  ));
END
$r6e_funding_entry_digest$;
ALTER FUNCTION editorial.funding_disclosure_entry_digest_v1(jsonb)
  OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_entry_set_digest_v1(
  p_entry_count integer,
  p_members jsonb
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_entry_set_digest$
BEGIN
  IF p_entry_count IS NULL OR p_entry_count<0 OR p_entry_count>10000
     OR p_members IS NULL OR jsonb_typeof(p_members)<>'array'
     OR jsonb_array_length(p_members)<>p_entry_count THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_ENTRY_SET_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_DISCLOSURE_ENTRY_SET_V1',
    'schemaVersion',1,'entryCount',p_entry_count,'members',p_members
  ));
END
$r6e_funding_entry_set_digest$;
ALTER FUNCTION editorial.funding_disclosure_entry_set_digest_v1(integer,jsonb)
  OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_policy_request_outcome_digest_v1(
  p_total integer,
  p_accepted integer,
  p_partially_accepted integer,
  p_rejected integer,
  p_withdrawn integer,
  p_pending integer
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_policy_outcome_digest$
BEGIN
  IF p_total IS NULL OR p_accepted IS NULL OR p_partially_accepted IS NULL
     OR p_rejected IS NULL OR p_withdrawn IS NULL OR p_pending IS NULL
     OR p_total<0 OR p_accepted<0 OR p_partially_accepted<0 OR p_rejected<0
     OR p_withdrawn<0 OR p_pending<0
     OR p_total<>p_accepted+p_partially_accepted+p_rejected+p_withdrawn+p_pending
  THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_POLICY_OUTCOME_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_POLICY_REQUEST_OUTCOME_V1',
    'schemaVersion',1,'total',p_total,'accepted',p_accepted,
    'partiallyAccepted',p_partially_accepted,'rejected',p_rejected,
    'withdrawn',p_withdrawn,'pending',p_pending
  ));
END
$r6e_funding_policy_outcome_digest$;
ALTER FUNCTION
  editorial.funding_disclosure_policy_request_outcome_digest_v1(
    integer,integer,integer,integer,integer,integer
  ) OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_public_content_digest_v1(
  p_revision editorial.funding_public_revision_v1,
  p_entries editorial.funding_public_entry_v1[]
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_public_content_digest$
BEGIN
  IF p_revision IS NULL OR p_entries IS NULL
     OR cardinality(p_entries)>10000 THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_PUBLIC_CONTENT_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_DISCLOSURE_PUBLIC_CONTENT_V1',
    'schemaVersion',1,
    'revision',(to_jsonb(p_revision)-'public_content_digest')
      -'revision_digest',
    'entries',to_jsonb(p_entries)
  ));
END
$r6e_funding_public_content_digest$;
ALTER FUNCTION editorial.funding_disclosure_public_content_digest_v1(
  editorial.funding_public_revision_v1,editorial.funding_public_entry_v1[]
) OWNER TO gurine_migrator;

CREATE FUNCTION editorial.funding_disclosure_revision_digest_v1(
  p_revision jsonb
) RETURNS char(64)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6e_funding_revision_digest$
BEGIN
  IF p_revision IS NULL OR jsonb_typeof(p_revision)<>'object'
     OR p_revision ? 'revision_digest' OR p_revision ? 'created_at' THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_REVISION_PREIMAGE_INVALID'
      USING ERRCODE='22023';
  END IF;
  RETURN editorial.funding_disclosure_sha256_v1(jsonb_build_object(
    'domain','GURINE_FUNDING_DISCLOSURE_REVISION_V1',
    'schemaVersion',1,'revision',p_revision
  ));
END
$r6e_funding_revision_digest$;
ALTER FUNCTION editorial.funding_disclosure_revision_digest_v1(jsonb)
  OWNER TO gurine_migrator;

REVOKE ALL ON FUNCTION
  editorial.funding_disclosure_sha256_v1(jsonb),
  editorial.funding_disclosure_conditional_gate_set_digest_v1(jsonb),
  editorial.funding_disclosure_source_entry_set_digest_v1(jsonb),
  editorial.funding_disclosure_counterparty_group_set_digest_v1(jsonb),
  editorial.funding_disclosure_independent_review_set_digest_v1(jsonb),
  editorial.funding_disclosure_source_link_set_digest_v1(text[]),
  editorial.funding_disclosure_entry_digest_v1(jsonb),
  editorial.funding_disclosure_entry_set_digest_v1(integer,jsonb),
  editorial.funding_disclosure_policy_request_outcome_digest_v1(
    integer,integer,integer,integer,integer,integer
  ),
  editorial.funding_disclosure_public_content_digest_v1(
    editorial.funding_public_revision_v1,
    editorial.funding_public_entry_v1[]
  ),
  editorial.funding_disclosure_revision_digest_v1(jsonb)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  editorial.funding_disclosure_conditional_gate_set_digest_v1(jsonb),
  editorial.funding_disclosure_source_entry_set_digest_v1(jsonb),
  editorial.funding_disclosure_counterparty_group_set_digest_v1(jsonb),
  editorial.funding_disclosure_independent_review_set_digest_v1(jsonb),
  editorial.funding_disclosure_source_link_set_digest_v1(text[]),
  editorial.funding_disclosure_entry_digest_v1(jsonb),
  editorial.funding_disclosure_entry_set_digest_v1(integer,jsonb),
  editorial.funding_disclosure_policy_request_outcome_digest_v1(
    integer,integer,integer,integer,integer,integer
  ),
  editorial.funding_disclosure_public_content_digest_v1(
    editorial.funding_public_revision_v1,
    editorial.funding_public_entry_v1[]
  ),
  editorial.funding_disclosure_revision_digest_v1(jsonb)
TO gurine_migrator;

-- R6E_ACTION_EXECUTION_OWNER_FUNCTIONS

-- Semantic fences use this closed result instead of overloading SQLSTATE
-- 40001, which remains reserved for an actual PostgreSQL serialization retry.
CREATE FUNCTION ops.economics_import_owner_result_v1(
  p_disposition text,
  p_code text,
  p_receipt jsonb
) RETURNS jsonb
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
  SELECT jsonb_build_object(
    'schemaVersion','economics-import-owner-result.v1',
    'disposition',p_disposition,
    'retryable',false,
    'code',p_code,
    'receipt',COALESCE(p_receipt,'{}'::jsonb)
  )
$$;
ALTER FUNCTION ops.economics_import_owner_result_v1(text,text,jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.economics_import_owner_result_v1(text,text,jsonb) FROM PUBLIC;

-- R6E_ACTION_EXECUTION_OWNER_FUNCTIONS_CLAIM

CREATE FUNCTION ops.economics_import_execution_binding_code_v1(
  p_job_id uuid,
  p_job_lease_token uuid,
  p_job_fencing_token bigint,
  p_event_id uuid,
  p_execution_id uuid,
  p_generation bigint,
  p_execution_digest char(64),
  p_target_request_sha256 char(64),
  p_worker_id text,
  p_require_live_producer boolean
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,raw,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_job ops.jobs%ROWTYPE;
  v_inbox ops.inbox%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
  v_auth ops.execution_authorizations%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_initial ops.execution_receipts%ROWTYPE;
  v_proposal ops.action_proposals%ROWTYPE;
  v_version ops.action_proposal_versions%ROWTYPE;
  v_detail ops.action_approval_economics_import_details%ROWTYPE;
  v_decision ops.action_decisions%ROWTYPE;
  v_assignment ops.action_review_assignments%ROWTYPE;
  v_payload jsonb;
  v_expected_counted_digest char(64);
  v_expected_evidence_digest char(64);
  v_expected_proposer_capabilities char(64);
  v_expected_reviewer_capabilities char(64);
  v_evidence_count bigint;
  v_capability_count bigint;
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR p_job_id IS NULL OR p_execution_id IS NULL
     OR p_generation IS DISTINCT FROM 1
     OR p_require_live_producer IS NULL THEN
    RETURN 'BINDING_REJECTED';
  END IF;

  SELECT job.* INTO v_job
  FROM ops.jobs AS job
  WHERE job.id=p_job_id
  FOR UPDATE;
  IF NOT FOUND OR v_job.job_type IS DISTINCT FROM 'EVENT_DELIVERY'
     OR v_job.queue IS DISTINCT FROM 'workflow-worker'
     OR jsonb_typeof(v_job.payload) IS DISTINCT FROM 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_job.payload))<>8
     OR NOT v_job.payload ?& ARRAY[
       'consumerId','eventType','aggregateType','aggregateId','aggregateVersion',
       'eventId','payload','occurredAt'
     ]
     OR v_job.payload->>'consumerId'
       IS DISTINCT FROM 'action-execution-worker'
     OR v_job.payload->>'eventType'
       IS DISTINCT FROM 'action.execution_authorized.v1'
     OR v_job.payload->>'aggregateType' IS DISTINCT FROM 'action_execution'
     OR v_job.payload->>'aggregateId' IS DISTINCT FROM p_execution_id::text
     OR COALESCE(v_job.payload->>'eventId','') !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     OR COALESCE(v_job.payload->>'aggregateVersion','') !~ '^[0-9]+$'
     OR COALESCE(v_job.payload->>'occurredAt','')='' THEN
    RETURN 'BINDING_REJECTED';
  END IF;
  IF p_event_id IS NOT NULL
     AND (v_job.payload->>'eventId')::uuid IS DISTINCT FROM p_event_id THEN
    RETURN 'BINDING_REJECTED';
  END IF;
  IF p_require_live_producer THEN
    IF p_job_lease_token IS NULL OR p_job_fencing_token IS NULL
       OR p_job_fencing_token<1 OR p_worker_id IS NULL
       OR length(btrim(p_worker_id)) NOT BETWEEN 1 AND 160
       OR v_job.status IS DISTINCT FROM 'RUNNING'
       OR v_job.lease_owner IS DISTINCT FROM p_worker_id
       OR v_job.lease_token IS DISTINCT FROM p_job_lease_token
       OR v_job.fencing_token IS DISTINCT FROM p_job_fencing_token THEN
      RETURN 'PRODUCER_FENCE_STALE';
    END IF;
    IF v_job.lease_expires_at IS NULL OR v_job.lease_expires_at<=v_now THEN
      RETURN 'PRODUCER_LEASE_EXPIRED';
    END IF;
  END IF;

  v_payload:=v_job.payload->'payload';
  IF jsonb_typeof(v_payload) IS DISTINCT FROM 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_payload))<>8
     OR NOT v_payload ?& ARRAY[
       'executionId','generation','actionKind','decisionDigest',
       'executionDigest','targetCommand','targetRequestSha256','expiresAt'
     ]
     OR v_payload->>'executionId' IS DISTINCT FROM p_execution_id::text
     OR v_payload->>'generation' IS DISTINCT FROM p_generation::text
     OR v_payload->>'actionKind' IS DISTINCT FROM 'ECONOMICS_IMPORT'
     OR v_payload->>'targetCommand'
       IS DISTINCT FROM 'private.ExecuteEconomicsImport'
     OR COALESCE(v_payload->>'decisionDigest','') !~ '^[0-9a-f]{64}$'
     OR COALESCE(v_payload->>'executionDigest','') !~ '^[0-9a-f]{64}$'
     OR COALESCE(v_payload->>'targetRequestSha256','')
       !~ '^[0-9a-f]{64}$'
     OR COALESCE(v_payload->>'expiresAt','')='' THEN
    RETURN 'BINDING_REJECTED';
  END IF;
  IF p_execution_digest IS NOT NULL
     AND btrim(p_execution_digest::text)
       IS DISTINCT FROM v_payload->>'executionDigest' THEN
    RETURN 'IDEMPOTENCY_CONFLICT';
  END IF;
  IF p_target_request_sha256 IS NOT NULL
     AND btrim(p_target_request_sha256::text)
       IS DISTINCT FROM v_payload->>'targetRequestSha256' THEN
    RETURN 'IDEMPOTENCY_CONFLICT';
  END IF;

  SELECT inbox.* INTO v_inbox
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='action-execution-worker'
    AND inbox.event_id=(v_job.payload->>'eventId')::uuid
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 'BINDING_REJECTED';
  END IF;
  IF p_require_live_producer
     AND (v_inbox.processed_at IS NOT NULL
       OR v_inbox.result IS DISTINCT FROM 'DISPATCHED:'||p_job_id::text) THEN
    RETURN 'EXECUTION_NOT_CLAIMABLE';
  END IF;

  SELECT event.* INTO v_event
  FROM ops.outbox AS event
  WHERE event.id=(v_job.payload->>'eventId')::uuid
  FOR SHARE;
  IF NOT FOUND OR v_event.aggregate_type IS DISTINCT FROM 'action_execution'
     OR v_event.aggregate_id IS DISTINCT FROM p_execution_id::text
     OR v_event.aggregate_version IS DISTINCT FROM p_generation
     OR v_event.event_type IS DISTINCT FROM 'action.execution_authorized.v1'
     OR v_event.payload IS DISTINCT FROM v_payload
     OR v_event.occurred_at
       IS DISTINCT FROM (v_job.payload->>'occurredAt')::timestamptz THEN
    RETURN 'BINDING_REJECTED';
  END IF;

  SELECT auth.* INTO v_auth
  FROM ops.execution_authorizations AS auth
  WHERE auth.execution_id=p_execution_id AND auth.generation=p_generation
  FOR SHARE;
  IF NOT FOUND OR v_auth.authorization_kind
       IS DISTINCT FROM (CASE WHEN p_generation=1
         THEN 'INITIAL_APPROVAL' ELSE 'SAFE_RETRY' END)
     OR v_auth.action_kind IS DISTINCT FROM 'ECONOMICS_IMPORT'
     OR v_auth.executor_id IS DISTINCT FROM 'private.ExecuteEconomicsImport'
     OR v_auth.transport IS DISTINCT FROM 'PRIVATE_APPLICATION_COMMAND'
     OR v_auth.required_capability IS DISTINCT FROM 'economics.import'
     OR v_auth.target_request_schema_version
       IS DISTINCT FROM 'action-payload.v1'
     OR v_auth.effect_boundary IS DISTINCT FROM 'DATABASE_ONLY'
     OR v_auth.cost_class IS DISTINCT FROM 'NO_PAID_EGRESS'
     OR v_auth.provider_config_id IS NOT NULL
     OR v_auth.provider_config_version IS NOT NULL
     OR btrim(v_auth.provider_configuration_digest::text) IS DISTINCT FROM
       '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde'
     OR btrim(v_auth.provider_idempotency_key_sha256::text) IS DISTINCT FROM
       '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74'
     OR v_auth.budget_reservation_id IS NOT NULL
     OR btrim(v_auth.budget_reservation_digest::text) IS DISTINCT FROM
       'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde'
     OR v_auth.outbox_id IS DISTINCT FROM v_event.id
     OR btrim(v_auth.execution_digest::text)
       IS DISTINCT FROM v_payload->>'executionDigest'
     OR btrim(v_auth.terminal_decision_receipt_digest::text)
       IS DISTINCT FROM v_payload->>'decisionDigest'
     OR btrim(v_auth.target_request_sha256::text)
       IS DISTINCT FROM v_payload->>'targetRequestSha256'
     OR v_auth.expires_at IS DISTINCT FROM
       (v_payload->>'expiresAt')::timestamptz
     OR cardinality(v_auth.counted_decision_ids)<>1
     OR cardinality(v_auth.counted_decision_receipt_digests)<>1 THEN
    RETURN 'BINDING_REJECTED';
  END IF;
  IF p_require_live_producer AND v_auth.expires_at<=v_now THEN
    RETURN 'AUTHORIZATION_EXPIRED';
  END IF;

  SELECT effect.* INTO v_effect
  FROM ops.in_flight_effects AS effect
  WHERE effect.id=p_execution_id
  FOR UPDATE;
  SELECT attempt.* INTO v_attempt
  FROM ops.execution_attempts AS attempt
  WHERE attempt.execution_id=p_execution_id
    AND attempt.generation=p_generation
  FOR UPDATE;
  SELECT receipt.* INTO v_initial
  FROM ops.execution_receipts AS receipt
  WHERE receipt.execution_id=p_execution_id
    AND receipt.generation=p_generation
    AND receipt.receipt_sequence=1
  FOR SHARE;
  IF v_effect.id IS NULL OR v_attempt.id IS NULL OR v_initial.id IS NULL
     OR v_effect.effect_type IS DISTINCT FROM 'ACTION_EXECUTION'
     OR v_effect.action_kind IS DISTINCT FROM 'ECONOMICS_IMPORT'
     OR v_effect.action_proposal_id IS DISTINCT FROM v_auth.proposal_id
     OR v_effect.action_proposal_version IS DISTINCT FROM v_auth.proposal_version
     OR v_effect.approval_digest IS DISTINCT FROM v_auth.approval_digest
     OR v_effect.current_generation IS DISTINCT FROM p_generation
     OR v_attempt.target_request_sha256
       IS DISTINCT FROM v_auth.target_request_sha256
     OR v_attempt.rendered_bytes_digest
       IS DISTINCT FROM v_auth.rendered_bytes_digest
     OR v_attempt.provider_config_id IS NOT NULL
     OR v_attempt.provider_config_version IS NOT NULL
     OR v_attempt.provider_configuration_digest
       IS DISTINCT FROM v_auth.provider_configuration_digest
     OR v_attempt.provider_idempotency_key_sha256
       IS DISTINCT FROM v_auth.provider_idempotency_key_sha256
     OR v_attempt.budget_reservation_id
       IS DISTINCT FROM v_auth.budget_reservation_id
     OR v_attempt.budget_reservation_digest
       IS DISTINCT FROM v_auth.budget_reservation_digest
     OR v_effect.last_receipt_sequence
       IS DISTINCT FROM v_attempt.last_receipt_sequence
     OR v_effect.last_receipt_digest
       IS DISTINCT FROM v_attempt.last_receipt_digest
     OR v_initial.receipt_kind IS DISTINCT FROM 'AUTHORIZATION_QUEUED'
     OR v_initial.aggregate_state IS DISTINCT FROM 'QUEUED'
     OR v_initial.attempt_state IS DISTINCT FROM 'QUEUED'
     OR v_initial.outbox_id IS DISTINCT FROM v_auth.outbox_id
     OR v_initial.request_id IS DISTINCT FROM v_auth.request_id
     OR v_initial.audit_event_id IS DISTINCT FROM v_auth.audit_event_id
     OR v_initial.proof_kind IS DISTINCT FROM 'NO_EGRESS'
     OR v_initial.proof_digest IS DISTINCT FROM v_auth.target_request_sha256 THEN
    RETURN 'BINDING_REJECTED';
  END IF;

  SELECT proposal.* INTO v_proposal
  FROM ops.action_proposals AS proposal
  WHERE proposal.id=v_auth.proposal_id
  FOR SHARE;
  SELECT version.* INTO v_version
  FROM ops.action_proposal_versions AS version
  WHERE version.proposal_id=v_auth.proposal_id
    AND version.version=v_auth.proposal_version
  FOR SHARE;
  SELECT detail.* INTO v_detail
  FROM ops.action_approval_economics_import_details AS detail
  WHERE detail.proposal_id=v_auth.proposal_id
    AND detail.proposal_version=v_auth.proposal_version
  FOR SHARE;
  IF v_proposal.id IS NULL OR v_version.proposal_id IS NULL
     OR v_detail.proposal_id IS NULL
     OR v_proposal.action_kind IS DISTINCT FROM 'ECONOMICS_IMPORT'
     OR v_proposal.target_type IS DISTINCT FROM 'ECONOMICS_IMPORT'
     OR v_proposal.current_version IS DISTINCT FROM v_auth.proposal_version
     OR v_version.state IS DISTINCT FROM 'APPROVED'
     OR v_version.approval_digest IS DISTINCT FROM v_auth.approval_digest
     OR v_version.action_detail_kind IS DISTINCT FROM 'ECONOMICS_IMPORT'
     OR v_version.operation_id
       IS DISTINCT FROM 'private.ExecuteEconomicsImport'
     OR v_version.required_capability IS DISTINCT FROM 'economics.import'
     OR v_version.target_request_digest
       IS DISTINCT FROM v_auth.target_request_sha256
     OR v_version.content_digest IS DISTINCT FROM v_auth.target_request_sha256
     OR v_version.payload_encrypted
       IS DISTINCT FROM v_auth.target_request_encrypted
     OR v_version.effect_idempotency_key_sha256
       IS DISTINCT FROM v_auth.command_idempotency_key_sha256
     OR v_detail.detail_kind IS DISTINCT FROM 'ECONOMICS_IMPORT'
     OR v_detail.action_detail_digest
       IS DISTINCT FROM v_version.action_detail_digest
     OR v_detail.detail_binding_canonical
       IS DISTINCT FROM v_version.action_detail_canonical
     OR v_detail.approval_digest IS DISTINCT FROM v_auth.approval_digest
     OR v_detail.content_digest IS DISTINCT FROM v_version.content_digest
     OR v_detail.operation_id IS DISTINCT FROM
       (v_detail.operation_value).import_kind
     OR v_detail.operation_canonical IS DISTINCT FROM
       ops.canonical_jsonb_v1(to_jsonb(v_detail.operation_value))
     OR v_detail.operation_digest IS DISTINCT FROM encode(
       extensions.digest(v_detail.operation_canonical,'sha256'),'hex'
     )
     OR v_detail.creator_actor_id IS DISTINCT FROM v_proposal.created_by
     OR v_detail.source_evidence_set_digest
       IS DISTINCT FROM v_version.evidence_set_digest
     OR v_detail.import_policy_digest
       IS DISTINCT FROM v_version.policy_snapshot_digest THEN
    RETURN 'BINDING_REJECTED';
  END IF;

  SELECT decision.* INTO v_decision
  FROM ops.action_decisions AS decision
  WHERE decision.id=v_auth.terminal_decision_id
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN 'BINDING_REJECTED';
  END IF;
  SELECT assignment.* INTO v_assignment
  FROM ops.action_review_assignments AS assignment
  WHERE assignment.id=v_decision.assignment_id
  FOR SHARE;
  v_expected_counted_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'decisionIds',to_jsonb(v_auth.counted_decision_ids),
      'decisionReceiptDigests',
        to_jsonb(v_auth.counted_decision_receipt_digests)
    )),'sha256'
  ),'hex');
  IF v_assignment.id IS NULL
     OR v_auth.counted_decision_ids[1] IS DISTINCT FROM v_decision.id
     OR v_auth.counted_decision_receipt_digests[1]
       IS DISTINCT FROM btrim(v_decision.receipt_digest::text)
     OR v_auth.counted_decision_set_digest
       IS DISTINCT FROM v_expected_counted_digest
     OR v_decision.proposal_id IS DISTINCT FROM v_auth.proposal_id
     OR v_decision.proposal_version IS DISTINCT FROM v_auth.proposal_version
     OR v_decision.approval_digest IS DISTINCT FROM v_auth.approval_digest
     OR v_decision.record_kind IS DISTINCT FROM 'DECISION'
     OR v_decision.decision_kind IS DISTINCT FROM 'APPROVE'
     OR NOT v_decision.counts_toward_quorum
     OR NOT v_decision.quorum_satisfied_after
     OR v_decision.resulting_proposal_state IS DISTINCT FROM 'APPROVED'
     OR v_decision.execution_id IS DISTINCT FROM p_execution_id
     OR v_decision.receipt_digest
       IS DISTINCT FROM v_auth.terminal_decision_receipt_digest
     OR v_decision.assurance IS DISTINCT FROM 'STEP_UP'
     OR v_decision.step_up_authorization_id IS NULL
     OR v_decision.step_up_authorization_digest IS NULL
     OR v_decision.step_up_authorization_receipt_digest IS NULL
     OR v_decision.step_up_authorization_receipt_canonical IS NULL
     OR v_decision.step_up_issued_at IS NULL
     OR v_decision.step_up_expires_at IS NULL
     OR v_decision.step_up_issued_at>v_decision.decided_at
     OR v_decision.decided_at>=v_decision.step_up_expires_at
     OR v_decision.actor_id=v_proposal.created_by
     OR v_assignment.proposal_id IS DISTINCT FROM v_auth.proposal_id
     OR v_assignment.proposal_version IS DISTINCT FROM v_auth.proposal_version
     OR v_assignment.approval_digest IS DISTINCT FROM v_auth.approval_digest
     OR v_assignment.slot_id IS DISTINCT FROM 'economics_reviewer'
     OR v_assignment.slot_ordinal IS DISTINCT FROM 1
     OR v_assignment.required_capability IS DISTINCT FROM 'actions.review'
     OR v_assignment.approve_assurance IS DISTINCT FROM 'STEP_UP'
     OR v_assignment.allowed_role_codes IS DISTINCT FROM
       ARRAY['EXECUTIVE_APPROVER','OPERATIONS']::text[]
     OR v_assignment.reviewer_id IS DISTINCT FROM v_decision.actor_id
     OR v_assignment.state IS DISTINCT FROM 'COMPLETED'
     OR NOT (v_proposal.created_by=ANY(v_assignment.excluded_actor_ids))
     OR v_assignment.conflict_target_id IS DISTINCT FROM v_auth.proposal_id
     OR v_assignment.conflict_target_version IS DISTINCT FROM v_auth.proposal_version
     OR v_assignment.conflict_target_digest IS DISTINCT FROM v_auth.approval_digest
     OR v_assignment.conflict_evaluation_state
       NOT IN ('CLEAR','DISCLOSURE_REQUIRED')
     OR v_assignment.conflict_valid_until<v_decision.decided_at THEN
    RETURN 'BINDING_REJECTED';
  END IF;

  PERFORM 1
  FROM ops.user_roles AS membership
  JOIN ops.roles AS role ON role.id=membership.role_id
  JOIN ops.role_capabilities AS capability
    ON capability.role_id=role.id
  WHERE membership.user_id IN (v_proposal.created_by,v_decision.actor_id)
    AND membership.revoked_at IS NULL
    AND (membership.expires_at IS NULL OR membership.expires_at>v_now)
  FOR SHARE OF membership,role,capability;
  SELECT count(DISTINCT capability.capability_code) INTO v_capability_count
  FROM ops.users AS actor
  JOIN ops.user_roles AS membership ON membership.user_id=actor.id
  JOIN ops.roles AS role ON role.id=membership.role_id
  JOIN ops.role_capabilities AS capability ON capability.role_id=role.id
  WHERE actor.id=v_proposal.created_by AND actor.status='ACTIVE'
    AND membership.revoked_at IS NULL
    AND (membership.expires_at IS NULL OR membership.expires_at>v_now)
    AND capability.capability_code IN ('actions.propose','budgets.manage');
  IF v_capability_count<>2 THEN
    RETURN 'BINDING_REJECTED';
  END IF;
  SELECT count(DISTINCT capability.capability_code) INTO v_capability_count
  FROM ops.users AS actor
  JOIN ops.user_roles AS membership ON membership.user_id=actor.id
  JOIN ops.roles AS role ON role.id=membership.role_id
  JOIN ops.role_capabilities AS capability ON capability.role_id=role.id
  WHERE actor.id=v_decision.actor_id AND actor.status='ACTIVE'
    AND role.code=ANY(v_assignment.allowed_role_codes)
    AND membership.revoked_at IS NULL
    AND (membership.expires_at IS NULL OR membership.expires_at>v_now)
    AND capability.capability_code IN ('actions.review','budgets.manage');
  IF v_capability_count<>2 THEN
    RETURN 'BINDING_REJECTED';
  END IF;
  v_expected_proposer_capabilities:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','economics-import-capability-set.v1',
      'capabilities',jsonb_build_array('actions.propose','budgets.manage')
    )),'sha256'
  ),'hex');
  v_expected_reviewer_capabilities:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','economics-import-capability-set.v1',
      'capabilities',jsonb_build_array('actions.review','budgets.manage')
    )),'sha256'
  ),'hex');
  IF v_detail.proposer_capability_set_digest
       IS DISTINCT FROM v_expected_proposer_capabilities
     OR v_detail.reviewer_capability_set_digest
       IS DISTINCT FROM v_expected_reviewer_capabilities THEN
    RETURN 'BINDING_REJECTED';
  END IF;

  PERFORM 1 FROM raw.evidence_segments AS evidence
  WHERE evidence.id=ANY(v_detail.source_evidence_segment_ids)
  FOR SHARE;
  SELECT count(*) INTO v_evidence_count
  FROM unnest(
    v_detail.source_evidence_segment_ids,
    v_detail.source_evidence_digests
  ) AS expected(segment_id,segment_digest)
  JOIN raw.evidence_segments AS evidence
    ON evidence.id=expected.segment_id
   AND evidence.segment_digest=expected.segment_digest;
  v_expected_evidence_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','economics-import-evidence-set.v1',
      'segmentIds',to_jsonb(v_detail.source_evidence_segment_ids),
      'segmentDigests',to_jsonb(v_detail.source_evidence_digests)
    )),'sha256'
  ),'hex');
  IF v_evidence_count<>cardinality(v_detail.source_evidence_segment_ids)
     OR v_detail.source_evidence_set_digest
       IS DISTINCT FROM v_expected_evidence_digest THEN
    RETURN 'BINDING_REJECTED';
  END IF;
  RETURN NULL;
END
$$;
ALTER FUNCTION ops.economics_import_execution_binding_code_v1(
  uuid,uuid,bigint,uuid,uuid,bigint,char(64),char(64),text,boolean
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.economics_import_execution_binding_code_v1(
  uuid,uuid,bigint,uuid,uuid,bigint,char(64),char(64),text,boolean
) FROM PUBLIC;

-- R6E_ACTION_EXECUTION_OWNER_FUNCTIONS_CLAIM_ENTRY

CREATE FUNCTION ops.claim_economics_import_execution_v1(
  p_job_id uuid,
  p_job_lease_token uuid,
  p_job_fencing_token bigint,
  p_event_id uuid,
  p_execution_id uuid,
  p_generation bigint,
  p_execution_digest char(64),
  p_target_request_sha256 char(64),
  p_worker_id text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_binding_code text;
  v_job ops.jobs%ROWTYPE;
  v_auth ops.execution_authorizations%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_detail ops.action_approval_economics_import_details%ROWTYPE;
  v_prior_receipt ops.execution_receipts%ROWTYPE;
  v_claim_receipt ops.execution_receipts%ROWTYPE;
  v_terminal_receipt ops.execution_receipts%ROWTYPE;
  v_receipt_id uuid:=gen_random_uuid();
  v_receipt_sequence bigint;
  v_execution_fence bigint;
  v_payload jsonb;
  v_canonical bytea;
  v_digest char(64);
  v_audit_id uuid;
  v_result jsonb;
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_economics_importer'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_IMPORTER_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF p_job_id IS NULL OR p_job_lease_token IS NULL
     OR p_job_fencing_token IS NULL OR p_job_fencing_token<1
     OR p_event_id IS NULL OR p_execution_id IS NULL
     OR p_generation IS DISTINCT FROM 1
     OR p_execution_digest IS NULL OR p_target_request_sha256 IS NULL
     OR btrim(p_execution_digest::text) !~ '^[0-9a-f]{64}$'
     OR btrim(p_target_request_sha256::text) !~ '^[0-9a-f]{64}$'
     OR p_worker_id IS NULL
     OR length(btrim(p_worker_id)) NOT BETWEEN 1 AND 160 THEN
    RETURN ops.economics_import_owner_result_v1(
      'BINDING_REJECTED','ECONOMICS_IMPORT_CLAIM_BINDING_REJECTED','{}'
    );
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'ECONOMICS_IMPORT_EXECUTION:'||p_execution_id::text||':'||p_generation::text,
    0
  ));

  -- A terminal receipt is immutable recovery truth.  It is replayed before
  -- consulting live lease/capability state, which may legitimately have
  -- changed after the atomic terminal commit.
  SELECT job.* INTO v_job FROM ops.jobs AS job
  WHERE job.id=p_job_id FOR UPDATE;
  SELECT auth.* INTO v_auth FROM ops.execution_authorizations AS auth
  WHERE auth.execution_id=p_execution_id AND auth.generation=p_generation
  FOR SHARE;
  SELECT effect.* INTO v_effect FROM ops.in_flight_effects AS effect
  WHERE effect.id=p_execution_id FOR UPDATE;
  SELECT attempt.* INTO v_attempt FROM ops.execution_attempts AS attempt
  WHERE attempt.execution_id=p_execution_id AND attempt.generation=p_generation
  FOR UPDATE;
  IF v_job.id IS NOT NULL AND v_auth.execution_id IS NOT NULL
     AND v_effect.id IS NOT NULL AND v_attempt.id IS NOT NULL
     AND v_effect.state IN ('SUCCEEDED','PERMANENT_FAILED')
     AND v_attempt.attempt_state=v_effect.state
     AND v_effect.last_receipt_sequence=v_attempt.last_receipt_sequence
     AND v_effect.last_receipt_digest=v_attempt.last_receipt_digest
     AND jsonb_typeof(v_job.payload)='object'
     AND v_job.payload->>'consumerId'='action-execution-worker'
     AND v_job.payload->>'eventType'='action.execution_authorized.v1'
     AND v_job.payload->>'aggregateType'='action_execution'
     AND v_job.payload->>'aggregateId'=p_execution_id::text
     AND v_job.payload->>'eventId'=p_event_id::text
     AND v_job.payload->'payload'->>'executionId'=p_execution_id::text
     AND v_job.payload->'payload'->>'generation'=p_generation::text
     AND v_job.payload->'payload'->>'actionKind'='ECONOMICS_IMPORT'
     AND v_job.payload->'payload'->>'targetCommand'
       ='private.ExecuteEconomicsImport'
     AND v_job.payload->'payload'->>'executionDigest'
       =btrim(p_execution_digest::text)
     AND v_job.payload->'payload'->>'targetRequestSha256'
       =btrim(p_target_request_sha256::text)
     AND v_auth.execution_digest=p_execution_digest
     AND v_auth.target_request_sha256=p_target_request_sha256 THEN
    SELECT receipt.* INTO v_terminal_receipt
    FROM ops.execution_receipts AS receipt
    WHERE receipt.execution_id=p_execution_id
      AND receipt.generation=p_generation
      AND receipt.receipt_sequence=v_effect.last_receipt_sequence
      AND receipt.receipt_digest=v_effect.last_receipt_digest
      AND receipt.receipt_kind=CASE v_effect.state
        WHEN 'SUCCEEDED' THEN 'EFFECT_SUCCEEDED'
        ELSE 'EFFECT_PERMANENT_FAILED' END
      AND receipt.aggregate_state=v_effect.state
      AND receipt.attempt_state=v_attempt.attempt_state
    FOR SHARE;
    IF FOUND
       AND jsonb_typeof(v_terminal_receipt.receipt_payload)='object'
       AND v_terminal_receipt.receipt_payload->>'producerJobId'=p_job_id::text
       AND v_terminal_receipt.receipt_payload->>'executionId'
         =p_execution_id::text
       AND v_terminal_receipt.receipt_payload->>'generation'=p_generation::text
       AND v_terminal_receipt.receipt_payload->>'executionDigest'
         =btrim(p_execution_digest::text)
       AND v_terminal_receipt.receipt_payload->>'targetRequestSha256'
         =btrim(p_target_request_sha256::text)
       AND v_terminal_receipt.receipt_payload->>'terminalKind' IN (
         'SUCCEEDED','OPERATION_REJECTED','PERMANENT_FAILED'
       ) THEN
      v_result:=v_terminal_receipt.receipt_payload||jsonb_build_object(
        'executionReceiptId',v_terminal_receipt.id,
        'executionReceiptSequence',v_terminal_receipt.receipt_sequence,
        'executionReceiptDigest',btrim(v_terminal_receipt.receipt_digest::text),
        'auditEventId',v_terminal_receipt.audit_event_id,
        'outboxEventId',v_terminal_receipt.outbox_id
      );
      IF (SELECT count(*) FROM jsonb_object_keys(v_result))<>32 THEN
        RETURN ops.economics_import_owner_result_v1(
          'BINDING_REJECTED',
          'ECONOMICS_IMPORT_TERMINAL_RECEIPT_BINDING_REJECTED','{}'
        );
      END IF;
      IF v_terminal_receipt.receipt_payload->>'terminalKind'='SUCCEEDED' THEN
        RETURN ops.economics_import_owner_result_v1(
          'COMPLETION_REPLAY','ECONOMICS_IMPORT_COMPLETION_REPLAYED',v_result
        );
      ELSIF v_terminal_receipt.receipt_payload->>'terminalKind'
          ='OPERATION_REJECTED' THEN
        RETURN ops.economics_import_owner_result_v1(
          'OPERATION_REJECTED','ECONOMICS_IMPORT_OPERATION_REJECTED',v_result
        );
      END IF;
      RETURN ops.economics_import_owner_result_v1(
        'FAILURE_REPLAY','ECONOMICS_IMPORT_FAILURE_REPLAYED',v_result
      );
    END IF;
    RETURN ops.economics_import_owner_result_v1(
      'BINDING_REJECTED',
      'ECONOMICS_IMPORT_TERMINAL_RECEIPT_BINDING_REJECTED','{}'
    );
  END IF;

  v_binding_code:=ops.economics_import_execution_binding_code_v1(
    p_job_id,p_job_lease_token,p_job_fencing_token,p_event_id,
    p_execution_id,p_generation,p_execution_digest,
    p_target_request_sha256,p_worker_id,true
  );
  IF v_binding_code IS NOT NULL THEN
    RETURN CASE v_binding_code
      WHEN 'PRODUCER_FENCE_STALE' THEN
        ops.economics_import_owner_result_v1(
          'PRODUCER_FENCE_STALE','ECONOMICS_IMPORT_PRODUCER_FENCE_STALE','{}'
        )
      WHEN 'PRODUCER_LEASE_EXPIRED' THEN
        ops.economics_import_owner_result_v1(
          'PRODUCER_LEASE_EXPIRED','ECONOMICS_IMPORT_PRODUCER_LEASE_EXPIRED','{}'
        )
      WHEN 'AUTHORIZATION_EXPIRED' THEN
        ops.economics_import_owner_result_v1(
          'AUTHORIZATION_EXPIRED','ECONOMICS_IMPORT_AUTHORIZATION_EXPIRED','{}'
        )
      WHEN 'EXECUTION_NOT_CLAIMABLE' THEN
        ops.economics_import_owner_result_v1(
          'EXECUTION_NOT_CLAIMABLE',
          'ECONOMICS_IMPORT_EXECUTION_NOT_CLAIMABLE','{}'
        )
      WHEN 'IDEMPOTENCY_CONFLICT' THEN
        ops.economics_import_owner_result_v1(
          'IDEMPOTENCY_CONFLICT','ECONOMICS_IMPORT_IDEMPOTENCY_CONFLICT','{}'
        )
      ELSE ops.economics_import_owner_result_v1(
        'BINDING_REJECTED','ECONOMICS_IMPORT_CLAIM_BINDING_REJECTED','{}'
      )
    END;
  END IF;

  SELECT job.* INTO STRICT v_job FROM ops.jobs AS job
  WHERE job.id=p_job_id FOR UPDATE;
  SELECT auth.* INTO STRICT v_auth FROM ops.execution_authorizations AS auth
  WHERE auth.execution_id=p_execution_id AND auth.generation=p_generation
  FOR SHARE;
  SELECT effect.* INTO STRICT v_effect FROM ops.in_flight_effects AS effect
  WHERE effect.id=p_execution_id FOR UPDATE;
  SELECT attempt.* INTO STRICT v_attempt FROM ops.execution_attempts AS attempt
  WHERE attempt.execution_id=p_execution_id AND attempt.generation=p_generation
  FOR UPDATE;
  SELECT detail.* INTO STRICT v_detail
  FROM ops.action_approval_economics_import_details AS detail
  WHERE detail.proposal_id=v_auth.proposal_id
    AND detail.proposal_version=v_auth.proposal_version
  FOR SHARE;

  IF v_effect.state IS DISTINCT FROM 'QUEUED'
     OR v_effect.state_version IS DISTINCT FROM 1
     OR v_attempt.attempt_state NOT IN ('QUEUED','CLAIMED') THEN
    RETURN ops.economics_import_owner_result_v1(
      'EXECUTION_NOT_CLAIMABLE',
      'ECONOMICS_IMPORT_EXECUTION_NOT_CLAIMABLE','{}'
    );
  END IF;
  SELECT receipt.* INTO v_claim_receipt
  FROM ops.execution_receipts AS receipt
  WHERE receipt.execution_id=p_execution_id
    AND receipt.generation=p_generation
    AND receipt.receipt_sequence=v_attempt.last_receipt_sequence
    AND receipt.receipt_digest=v_attempt.last_receipt_digest
    AND receipt.receipt_kind='LEASE_CLAIMED'
  FOR SHARE;
  IF v_attempt.attempt_state='CLAIMED'
     AND v_claim_receipt.id IS NOT NULL
     AND v_attempt.lease_owner=p_worker_id
     AND v_attempt.lease_token=p_job_lease_token
     AND v_attempt.lease_expires_at>v_now
     AND v_claim_receipt.receipt_payload->>'producerJobId'=p_job_id::text
     AND v_claim_receipt.receipt_payload->>'producerJobFencingToken'
       =p_job_fencing_token::text THEN
    v_result:=v_claim_receipt.receipt_payload||jsonb_build_object(
      'executionReceiptId',v_claim_receipt.id,
      'executionReceiptSequence',v_claim_receipt.receipt_sequence,
      'executionReceiptDigest',btrim(v_claim_receipt.receipt_digest::text)
    );
    IF (SELECT count(*) FROM jsonb_object_keys(v_result))<>25 THEN
      RETURN ops.economics_import_owner_result_v1(
        'BINDING_REJECTED','ECONOMICS_IMPORT_CLAIM_RECEIPT_BINDING_REJECTED','{}'
      );
    END IF;
    RETURN ops.economics_import_owner_result_v1(
      'CLAIM_REPLAY','ECONOMICS_IMPORT_CLAIM_REPLAYED',v_result
    );
  END IF;
  IF v_attempt.attempt_state='CLAIMED'
     AND (v_claim_receipt.id IS NULL OR v_attempt.lease_expires_at>v_now) THEN
    RETURN ops.economics_import_owner_result_v1(
      'EXECUTION_NOT_CLAIMABLE',
      'ECONOMICS_IMPORT_EXECUTION_NOT_CLAIMABLE','{}'
    );
  END IF;
  SELECT receipt.* INTO STRICT v_prior_receipt
  FROM ops.execution_receipts AS receipt
  WHERE receipt.execution_id=p_execution_id
    AND receipt.generation=p_generation
    AND receipt.receipt_sequence=v_attempt.last_receipt_sequence
    AND receipt.receipt_digest=v_attempt.last_receipt_digest
  FOR SHARE;
  IF v_prior_receipt.receipt_kind NOT IN ('AUTHORIZATION_QUEUED','LEASE_CLAIMED')
     OR v_effect.last_receipt_sequence IS DISTINCT FROM v_attempt.last_receipt_sequence
     OR v_effect.last_receipt_digest IS DISTINCT FROM v_attempt.last_receipt_digest THEN
    RETURN ops.economics_import_owner_result_v1(
      'BINDING_REJECTED','ECONOMICS_IMPORT_CLAIM_CHAIN_REJECTED','{}'
    );
  END IF;

  v_receipt_sequence:=v_attempt.last_receipt_sequence+1;
  v_execution_fence:=v_attempt.fencing_token+1;
  v_payload:=jsonb_build_object(
    'schemaVersion','economics-import-claim-receipt.v1',
    'producerJobId',p_job_id,
    'producerJobFencingToken',p_job_fencing_token,
    'producerJobLeaseExpiresAt',v_job.lease_expires_at,
    'eventId',p_event_id,
    'executionId',p_execution_id,
    'generation',p_generation,
    'attemptId',v_attempt.id,
    'executionFencingToken',v_execution_fence,
    'executionDigest',btrim(v_auth.execution_digest::text),
    'approvalDigest',btrim(v_auth.approval_digest::text),
    'countedDecisionSetDigest',btrim(v_auth.counted_decision_set_digest::text),
    'terminalDecisionReceiptDigest',
      btrim(v_auth.terminal_decision_receipt_digest::text),
    'effectIdempotencyKeySha256',
      btrim(v_auth.command_idempotency_key_sha256::text),
    'actionDetailDigest',btrim(v_detail.action_detail_digest::text),
    'targetRequestSha256',btrim(v_auth.target_request_sha256::text),
    'operationId',v_detail.operation_id,
    'operationDigest',btrim(v_detail.operation_digest::text),
    'sourceEvidenceSetDigest',
      btrim(v_detail.source_evidence_set_digest::text),
    'importPolicyDigest',btrim(v_detail.import_policy_digest::text),
    'asOf',v_detail.as_of,
    'authorizationExpiresAt',v_auth.expires_at
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_audit_id:=ops.append_audit_event(
    'workflow:economics-import:'||p_execution_id::text,
    'SERVICE','workflow-worker.economics-import-executor',NULL::uuid,
    'ECONOMICS_IMPORT_EXECUTION_CLAIMED','ActionExecution',
    p_execution_id::text,'economics.import','SUCCESS',NULL,
    v_auth.request_id,jsonb_build_object(
      'executionId',p_execution_id,'generation',p_generation,
      'attemptId',v_attempt.id,'executionFencingToken',v_execution_fence,
      'producerJobId',p_job_id,
      'producerJobFencingToken',p_job_fencing_token,
      'executionReceiptSequence',v_receipt_sequence,
      'executionReceiptDigest',v_digest
    )
  );
  INSERT INTO ops.execution_receipts(
    id,execution_id,generation,attempt_id,receipt_sequence,receipt_kind,
    mutates_aggregate_state,prior_aggregate_state,aggregate_state,
    aggregate_state_version,prior_attempt_state,attempt_state,fencing_token,
    cancellation_generation,proof_kind,proof_digest,receipt_payload,
    receipt_payload_canonical,budget_reservation_id,budget_reservation_digest,
    request_id,audit_event_id,outbox_id,observed_at,prior_receipt_digest,
    receipt_digest
  ) VALUES (
    v_receipt_id,p_execution_id,p_generation,v_attempt.id,v_receipt_sequence,
    'LEASE_CLAIMED',false,'QUEUED','QUEUED',v_effect.state_version,
    v_attempt.attempt_state,'CLAIMED',v_execution_fence,
    v_effect.cancellation_generation,'DEFINITIVE_NOT_ACCEPTED',
    v_detail.operation_digest,v_payload,v_canonical,v_auth.budget_reservation_id,
    v_auth.budget_reservation_digest,v_auth.request_id,v_audit_id,NULL,v_now,
    v_attempt.last_receipt_digest,v_digest
  );
  UPDATE ops.execution_attempts SET
    attempt_state='CLAIMED',state_version=state_version+1,
    lease_owner=p_worker_id,lease_token=p_job_lease_token,
    lease_expires_at=v_job.lease_expires_at,fencing_token=v_execution_fence,
    claimed_at=v_now,last_receipt_sequence=v_receipt_sequence,
    last_receipt_digest=v_digest,updated_at=v_now
  WHERE id=v_attempt.id
    AND state_version=v_attempt.state_version
    AND attempt_state=v_attempt.attempt_state
    AND last_receipt_sequence=v_attempt.last_receipt_sequence
    AND last_receipt_digest=v_attempt.last_receipt_digest;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'economics_import_claim_serialization_conflict'
      USING ERRCODE='40001';
  END IF;
  UPDATE ops.in_flight_effects SET
    last_receipt_sequence=v_receipt_sequence,
    last_receipt_digest=v_digest,updated_at=v_now
  WHERE id=p_execution_id
    AND state='QUEUED' AND state_version=v_effect.state_version
    AND last_receipt_sequence=v_effect.last_receipt_sequence
    AND last_receipt_digest=v_effect.last_receipt_digest;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'economics_import_effect_claim_serialization_conflict'
      USING ERRCODE='40001';
  END IF;
  v_result:=v_payload||jsonb_build_object(
    'executionReceiptId',v_receipt_id,
    'executionReceiptSequence',v_receipt_sequence,
    'executionReceiptDigest',btrim(v_digest::text)
  );
  IF (SELECT count(*) FROM jsonb_object_keys(v_result))<>25 THEN
    RAISE EXCEPTION 'economics_import_claim_receipt_internal_invalid'
      USING ERRCODE='XX000';
  END IF;
  RETURN ops.economics_import_owner_result_v1(
    'CLAIMED','ECONOMICS_IMPORT_EXECUTION_CLAIMED',v_result
  );
END
$$;
ALTER FUNCTION ops.claim_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,uuid,bigint,char(64),char(64),text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.claim_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,uuid,bigint,char(64),char(64),text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.claim_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,uuid,bigint,char(64),char(64),text
) TO gurine_economics_importer;

-- R6E_ACTION_EXECUTION_OWNER_FUNCTIONS_COMPLETE_FAIL

CREATE FUNCTION ops.economics_import_terminal_replay_v1(
  p_job_id uuid,
  p_execution_id uuid,
  p_generation bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_receipt ops.execution_receipts%ROWTYPE;
  v_result jsonb;
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR p_job_id IS NULL OR p_execution_id IS NULL
     OR p_generation IS NULL OR p_generation<1 THEN
    RETURN NULL;
  END IF;
  SELECT job.* INTO v_job FROM ops.jobs AS job
  WHERE job.id=p_job_id FOR UPDATE;
  SELECT effect.* INTO v_effect FROM ops.in_flight_effects AS effect
  WHERE effect.id=p_execution_id FOR UPDATE;
  SELECT attempt.* INTO v_attempt FROM ops.execution_attempts AS attempt
  WHERE attempt.execution_id=p_execution_id AND attempt.generation=p_generation
  FOR UPDATE;
  IF v_job.id IS NULL OR v_effect.id IS NULL OR v_attempt.id IS NULL
     OR v_effect.state NOT IN ('SUCCEEDED','PERMANENT_FAILED')
     OR v_attempt.attempt_state IS DISTINCT FROM v_effect.state
     OR v_effect.last_receipt_sequence
       IS DISTINCT FROM v_attempt.last_receipt_sequence
     OR v_effect.last_receipt_digest IS DISTINCT FROM v_attempt.last_receipt_digest
     OR jsonb_typeof(v_job.payload) IS DISTINCT FROM 'object'
     OR v_job.payload->>'consumerId' IS DISTINCT FROM 'action-execution-worker'
     OR v_job.payload->>'eventType'
       IS DISTINCT FROM 'action.execution_authorized.v1'
     OR v_job.payload->>'aggregateType' IS DISTINCT FROM 'action_execution'
     OR v_job.payload->>'aggregateId' IS DISTINCT FROM p_execution_id::text
     OR v_job.payload->'payload'->>'executionId'
       IS DISTINCT FROM p_execution_id::text
     OR v_job.payload->'payload'->>'generation'
       IS DISTINCT FROM p_generation::text
     OR v_job.payload->'payload'->>'actionKind'
       IS DISTINCT FROM 'ECONOMICS_IMPORT'
     OR v_job.payload->'payload'->>'targetCommand'
       IS DISTINCT FROM 'private.ExecuteEconomicsImport' THEN
    RETURN NULL;
  END IF;
  SELECT receipt.* INTO v_receipt
  FROM ops.execution_receipts AS receipt
  WHERE receipt.execution_id=p_execution_id
    AND receipt.generation=p_generation
    AND receipt.receipt_sequence=v_effect.last_receipt_sequence
    AND receipt.receipt_digest=v_effect.last_receipt_digest
    AND receipt.receipt_kind=CASE v_effect.state
      WHEN 'SUCCEEDED' THEN 'EFFECT_SUCCEEDED'
      ELSE 'EFFECT_PERMANENT_FAILED' END
    AND receipt.aggregate_state=v_effect.state
    AND receipt.attempt_state=v_attempt.attempt_state
  FOR SHARE;
  IF NOT FOUND OR jsonb_typeof(v_receipt.receipt_payload)<>'object'
     OR v_receipt.receipt_payload->>'producerJobId'<>p_job_id::text
     OR v_receipt.receipt_payload->>'executionId'<>p_execution_id::text
     OR v_receipt.receipt_payload->>'generation'<>p_generation::text
     OR v_receipt.receipt_payload->>'terminalKind' NOT IN (
       'SUCCEEDED','OPERATION_REJECTED','PERMANENT_FAILED'
     ) THEN
    RETURN NULL;
  END IF;
  v_result:=v_receipt.receipt_payload||jsonb_build_object(
    'executionReceiptId',v_receipt.id,
    'executionReceiptSequence',v_receipt.receipt_sequence,
    'executionReceiptDigest',btrim(v_receipt.receipt_digest::text),
    'auditEventId',v_receipt.audit_event_id,
    'outboxEventId',v_receipt.outbox_id
  );
  IF (SELECT count(*) FROM jsonb_object_keys(v_result))<>32 THEN
    RETURN NULL;
  END IF;
  RETURN v_result;
END
$$;
ALTER FUNCTION ops.economics_import_terminal_replay_v1(uuid,uuid,bigint)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.economics_import_terminal_replay_v1(uuid,uuid,bigint) FROM PUBLIC;

CREATE FUNCTION ops.terminalize_economics_import_execution_v1(
  p_job_id uuid,
  p_execution_id uuid,
  p_generation bigint,
  p_request_id uuid,
  p_terminal_kind text,
  p_result_set_digest char(64),
  p_error_code text,
  p_error_detail_digest char(64),
  p_notification_outbox_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_job ops.jobs%ROWTYPE;
  v_inbox ops.inbox%ROWTYPE;
  v_auth ops.execution_authorizations%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_detail ops.action_approval_economics_import_details%ROWTYPE;
  v_notification ops.outbox%ROWTYPE;
  v_target_state text;
  v_receipt_kind text;
  v_receipt_id uuid:=gen_random_uuid();
  v_receipt_sequence bigint;
  v_payload jsonb;
  v_canonical bytea;
  v_digest char(64);
  v_outbox_id uuid;
  v_audit_id uuid;
  v_job_result jsonb;
  v_result jsonb;
BEGIN
  IF session_user<>'gurine_economics_importer'
     OR p_job_id IS NULL OR p_execution_id IS NULL
     OR p_generation IS DISTINCT FROM 1 OR p_request_id IS NULL
     OR p_terminal_kind NOT IN (
       'SUCCEEDED','OPERATION_REJECTED','PERMANENT_FAILED'
     )
     OR (p_terminal_kind='SUCCEEDED' AND (
       p_result_set_digest IS NULL
       OR btrim(p_result_set_digest::text) !~ '^[0-9a-f]{64}$'
       OR p_error_code IS NOT NULL OR p_error_detail_digest IS NOT NULL
     ))
     OR (p_terminal_kind<>'SUCCEEDED' AND (
       p_result_set_digest IS NOT NULL OR p_error_code IS NULL
       OR length(btrim(p_error_code)) NOT BETWEEN 1 AND 100
       OR p_error_code !~ '^[A-Z][A-Z0-9_]{0,99}$'
       OR p_error_detail_digest IS NULL
       OR btrim(p_error_detail_digest::text) !~ '^[0-9a-f]{64}$'
       OR p_notification_outbox_event_id IS NOT NULL
     )) THEN
    RAISE EXCEPTION 'economics_import_terminal_input_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT job.* INTO STRICT v_job FROM ops.jobs AS job
  WHERE job.id=p_job_id FOR UPDATE;
  SELECT inbox.* INTO STRICT v_inbox FROM ops.inbox AS inbox
  WHERE inbox.consumer='action-execution-worker'
    AND inbox.event_id=(v_job.payload->>'eventId')::uuid
  FOR UPDATE;
  SELECT auth.* INTO STRICT v_auth FROM ops.execution_authorizations AS auth
  WHERE auth.execution_id=p_execution_id AND auth.generation=p_generation
  FOR SHARE;
  SELECT effect.* INTO STRICT v_effect FROM ops.in_flight_effects AS effect
  WHERE effect.id=p_execution_id FOR UPDATE;
  SELECT attempt.* INTO STRICT v_attempt FROM ops.execution_attempts AS attempt
  WHERE attempt.execution_id=p_execution_id AND attempt.generation=p_generation
  FOR UPDATE;
  SELECT detail.* INTO STRICT v_detail
  FROM ops.action_approval_economics_import_details AS detail
  WHERE detail.proposal_id=v_auth.proposal_id
    AND detail.proposal_version=v_auth.proposal_version
  FOR SHARE;
  IF p_terminal_kind='SUCCEEDED' THEN
    v_target_state:='SUCCEEDED';
    v_receipt_kind:='EFFECT_SUCCEEDED';
    IF v_effect.state IS DISTINCT FROM 'RUNNING'
       OR v_attempt.attempt_state IS DISTINCT FROM 'DISPATCHING' THEN
      RAISE EXCEPTION 'economics_import_success_terminal_state_invalid'
        USING ERRCODE='55000';
    END IF;
  ELSE
    v_target_state:='PERMANENT_FAILED';
    v_receipt_kind:='EFFECT_PERMANENT_FAILED';
    IF (p_terminal_kind='OPERATION_REJECTED' AND (
         v_effect.state IS DISTINCT FROM 'RUNNING'
         OR v_attempt.attempt_state IS DISTINCT FROM 'DISPATCHING'
       )) OR (p_terminal_kind='PERMANENT_FAILED' AND (
         v_effect.state IS DISTINCT FROM 'QUEUED'
         OR v_attempt.attempt_state IS DISTINCT FROM 'CLAIMED'
       )) THEN
      RAISE EXCEPTION 'economics_import_failure_terminal_state_invalid'
        USING ERRCODE='55000';
    END IF;
  END IF;
  IF v_job.status IS DISTINCT FROM 'RUNNING'
     OR v_inbox.processed_at IS NOT NULL
     OR v_inbox.result IS DISTINCT FROM 'DISPATCHED:'||p_job_id::text
     OR v_attempt.lease_token IS DISTINCT FROM v_job.lease_token
     OR v_attempt.lease_owner IS DISTINCT FROM v_job.lease_owner
     OR v_attempt.lease_expires_at IS NULL
     OR v_attempt.lease_expires_at<=v_now
     OR v_effect.last_receipt_sequence
       IS DISTINCT FROM v_attempt.last_receipt_sequence
     OR v_effect.last_receipt_digest IS DISTINCT FROM v_attempt.last_receipt_digest THEN
    RAISE EXCEPTION 'economics_import_terminal_fence_invalid'
      USING ERRCODE='55000';
  END IF;
  IF p_notification_outbox_event_id IS NOT NULL THEN
    SELECT event.* INTO v_notification FROM ops.outbox AS event
    WHERE event.id=p_notification_outbox_event_id FOR SHARE;
    IF NOT FOUND OR v_detail.operation_id<>'recordCollectionFailure'
       OR v_notification.event_type
         <>'notification.payment_review_requested.v1' THEN
      RAISE EXCEPTION 'economics_import_notification_binding_invalid'
        USING ERRCODE='23514';
    END IF;
  ELSIF p_terminal_kind='SUCCEEDED'
      AND v_detail.operation_id='recordCollectionFailure' THEN
    RAISE EXCEPTION 'economics_import_notification_missing'
      USING ERRCODE='23514';
  END IF;

  v_receipt_sequence:=v_attempt.last_receipt_sequence+1;
  v_payload:=jsonb_build_object(
    'schemaVersion','economics-import-terminal-receipt.v1',
    'terminalKind',p_terminal_kind,
    'producerJobId',p_job_id,
    'producerJobFencingToken',v_job.fencing_token,
    'eventId',(v_job.payload->>'eventId')::uuid,
    'executionId',p_execution_id,
    'generation',p_generation,
    'attemptId',v_attempt.id,
    'executionFencingToken',v_attempt.fencing_token,
    'executionDigest',btrim(v_auth.execution_digest::text),
    'approvalDigest',btrim(v_auth.approval_digest::text),
    'countedDecisionSetDigest',btrim(v_auth.counted_decision_set_digest::text),
    'terminalDecisionReceiptDigest',
      btrim(v_auth.terminal_decision_receipt_digest::text),
    'effectIdempotencyKeySha256',
      btrim(v_auth.command_idempotency_key_sha256::text),
    'actionDetailDigest',btrim(v_detail.action_detail_digest::text),
    'targetRequestSha256',btrim(v_auth.target_request_sha256::text),
    'operationId',v_detail.operation_id,
    'operationDigest',btrim(v_detail.operation_digest::text),
    'sourceEvidenceSetDigest',
      btrim(v_detail.source_evidence_set_digest::text),
    'importPolicyDigest',btrim(v_detail.import_policy_digest::text),
    'asOf',v_detail.as_of,
    'authorizationExpiresAt',v_auth.expires_at,
    'resultSetDigest',CASE WHEN p_result_set_digest IS NULL THEN NULL
      ELSE btrim(p_result_set_digest::text) END,
    'errorCode',p_error_code,
    'errorDetailDigest',CASE WHEN p_error_detail_digest IS NULL THEN NULL
      ELSE btrim(p_error_detail_digest::text) END,
    'notificationOutboxEventId',p_notification_outbox_event_id,
    'occurredAt',v_now
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_outbox_id:=ops.enqueue_outbox(
    'action_execution',p_execution_id::text,v_effect.state_version+1,
    'action.execution_completed.v1',jsonb_build_object(
      'executionId',p_execution_id,'generation',p_generation,
      'stateVersion',v_effect.state_version+1,
      'terminalOrReconciliationState',v_target_state,
      'executionDigest',btrim(v_auth.execution_digest::text),
      'receiptSequence',v_receipt_sequence,'receiptDigest',v_digest,
      'costFactIds','[]'::jsonb
    ),v_now
  );
  v_audit_id:=ops.append_audit_event(
    'workflow:economics-import:'||p_execution_id::text,
    'SERVICE','workflow-worker.economics-import-executor',NULL::uuid,
    CASE p_terminal_kind WHEN 'SUCCEEDED'
      THEN 'ECONOMICS_IMPORT_EXECUTION_COMPLETED'
      ELSE 'ECONOMICS_IMPORT_EXECUTION_PERMANENT_FAILED' END,
    'ActionExecution',p_execution_id::text,'economics.import',
    CASE p_terminal_kind WHEN 'SUCCEEDED' THEN 'SUCCESS'
      ELSE 'FAILED' END::ops.audit_outcome,
    p_error_code,p_request_id,jsonb_build_object(
      'executionId',p_execution_id,'generation',p_generation,
      'terminalKind',p_terminal_kind,'operationId',v_detail.operation_id,
      'resultSetDigest',p_result_set_digest,'errorCode',p_error_code,
      'errorDetailDigest',p_error_detail_digest,
      'executionReceiptSequence',v_receipt_sequence,
      'executionReceiptDigest',v_digest,'outboxEventId',v_outbox_id,
      'notificationOutboxEventId',p_notification_outbox_event_id
    )
  );
  INSERT INTO ops.execution_receipts(
    id,execution_id,generation,attempt_id,receipt_sequence,receipt_kind,
    mutates_aggregate_state,prior_aggregate_state,aggregate_state,
    aggregate_state_version,prior_attempt_state,attempt_state,fencing_token,
    cancellation_generation,proof_kind,proof_digest,receipt_payload,
    receipt_payload_canonical,budget_reservation_id,budget_reservation_digest,
    request_id,audit_event_id,outbox_id,observed_at,prior_receipt_digest,
    receipt_digest
  ) VALUES (
    v_receipt_id,p_execution_id,p_generation,v_attempt.id,v_receipt_sequence,
    v_receipt_kind,true,v_effect.state,v_target_state,v_effect.state_version+1,
    v_attempt.attempt_state,v_target_state,v_attempt.fencing_token,
    v_effect.cancellation_generation,'NO_EGRESS',
    COALESCE(p_result_set_digest,p_error_detail_digest),
    v_payload,v_canonical,v_auth.budget_reservation_id,
    v_auth.budget_reservation_digest,p_request_id,v_audit_id,v_outbox_id,v_now,
    v_attempt.last_receipt_digest,v_digest
  );
  UPDATE ops.execution_attempts SET
    attempt_state=v_target_state,state_version=state_version+1,
    lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
    terminal_proof_digest=COALESCE(p_result_set_digest,p_error_detail_digest),
    last_error_code=p_error_code,last_error_detail_digest=p_error_detail_digest,
    completed_at=v_now,last_receipt_sequence=v_receipt_sequence,
    last_receipt_digest=v_digest,updated_at=v_now
  WHERE id=v_attempt.id AND state_version=v_attempt.state_version
    AND attempt_state=v_attempt.attempt_state
    AND last_receipt_sequence=v_attempt.last_receipt_sequence
    AND last_receipt_digest=v_attempt.last_receipt_digest;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'economics_import_attempt_terminal_serialization_conflict'
      USING ERRCODE='40001';
  END IF;
  UPDATE ops.in_flight_effects SET
    state=v_target_state,state_version=state_version+1,
    last_receipt_sequence=v_receipt_sequence,last_receipt_digest=v_digest,
    terminal_at=v_now,updated_at=v_now
  WHERE id=p_execution_id AND state=v_effect.state
    AND state_version=v_effect.state_version
    AND last_receipt_sequence=v_effect.last_receipt_sequence
    AND last_receipt_digest=v_effect.last_receipt_digest;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'economics_import_effect_terminal_serialization_conflict'
      USING ERRCODE='40001';
  END IF;

  IF p_terminal_kind='SUCCEEDED' THEN
    v_job_result:=jsonb_build_object(
      'schemaVersion','economics-import-job-result.v1',
      'operationId',v_detail.operation_id,'terminalKind','SUCCEEDED',
      'executionReceiptId',v_receipt_id,
      'executionReceiptSequence',v_receipt_sequence,
      'executionReceiptDigest',btrim(v_digest::text),
      'resultSetDigest',btrim(p_result_set_digest::text)
    );
    UPDATE ops.jobs SET status='SUCCEEDED',lease_owner=NULL,lease_token=NULL,
      lease_expires_at=NULL,last_error_code=NULL,last_error_detail=NULL,
      completed_at=v_now,updated_at=v_now
    WHERE id=p_job_id AND status='RUNNING'
      AND lease_token=v_job.lease_token
      AND fencing_token=v_job.fencing_token;
    UPDATE ops.job_attempts SET finished_at=v_now,outcome='SUCCEEDED',
      error_code=NULL,error_detail=NULL,metrics=v_job_result
    WHERE job_id=p_job_id AND attempt=v_job.attempt_count
      AND worker_id=v_job.lease_owner
      AND fencing_token=v_job.fencing_token AND finished_at IS NULL;
    UPDATE ops.inbox SET processed_at=v_now,result=v_job_result::text
    WHERE consumer='action-execution-worker'
      AND event_id=(v_job.payload->>'eventId')::uuid
      AND processed_at IS NULL AND result='DISPATCHED:'||p_job_id::text;
  ELSE
    UPDATE ops.jobs SET status='FAILED',lease_owner=NULL,lease_token=NULL,
      lease_expires_at=NULL,last_error_code=p_error_code,
      last_error_detail=btrim(p_error_detail_digest::text),
      completed_at=v_now,updated_at=v_now
    WHERE id=p_job_id AND status='RUNNING'
      AND lease_token=v_job.lease_token
      AND fencing_token=v_job.fencing_token;
    UPDATE ops.job_attempts SET finished_at=v_now,outcome='FAILED',
      error_code=p_error_code,error_detail=btrim(p_error_detail_digest::text),
      metrics='{}'::jsonb
    WHERE job_id=p_job_id AND attempt=v_job.attempt_count
      AND worker_id=v_job.lease_owner
      AND fencing_token=v_job.fencing_token AND finished_at IS NULL;
    UPDATE ops.inbox SET processed_at=v_now,
      result='PERMANENT_FAILED:'||btrim(v_digest::text)
    WHERE consumer='action-execution-worker'
      AND event_id=(v_job.payload->>'eventId')::uuid
      AND processed_at IS NULL AND result='DISPATCHED:'||p_job_id::text;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'economics_import_producer_terminal_serialization_conflict'
      USING ERRCODE='40001';
  END IF;
  v_result:=v_payload||jsonb_build_object(
    'executionReceiptId',v_receipt_id,
    'executionReceiptSequence',v_receipt_sequence,
    'executionReceiptDigest',btrim(v_digest::text),
    'auditEventId',v_audit_id,'outboxEventId',v_outbox_id
  );
  IF (SELECT count(*) FROM jsonb_object_keys(v_result))<>32 THEN
    RAISE EXCEPTION 'economics_import_terminal_receipt_internal_invalid'
      USING ERRCODE='XX000';
  END IF;
  RETURN v_result;
END
$$;
ALTER FUNCTION ops.terminalize_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,text,char(64),text,char(64),uuid
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.terminalize_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,text,char(64),text,char(64),uuid
) FROM PUBLIC;

-- R6E_ACTION_EXECUTION_OWNER_FUNCTIONS_COMPLETE_ENTRY

CREATE FUNCTION ops.fail_economics_import_execution_v1(
  p_job_id uuid,
  p_job_lease_token uuid,
  p_job_fencing_token bigint,
  p_execution_id uuid,
  p_generation bigint,
  p_error_code text,
  p_error_detail_digest char(64),
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_claim ops.execution_receipts%ROWTYPE;
  v_binding_code text;
  v_terminal jsonb;
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_economics_importer'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_IMPORTER_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF p_job_id IS NULL OR p_job_lease_token IS NULL
     OR p_job_fencing_token IS NULL OR p_job_fencing_token<1
     OR p_execution_id IS NULL OR p_generation IS DISTINCT FROM 1
     OR p_request_id IS NULL OR p_error_detail_digest IS NULL
     OR btrim(p_error_detail_digest::text) !~ '^[0-9a-f]{64}$'
     OR p_error_code NOT IN (
       'ECONOMICS_IMPORT_CLAIM_RECEIPT_INVALID',
       'ECONOMICS_IMPORT_TARGET_DECRYPTION_FAILED',
       'ECONOMICS_IMPORT_TARGET_PAYLOAD_INVALID',
       'ECONOMICS_IMPORT_TARGET_BINDING_INVALID',
       'ECONOMICS_IMPORT_OPERATION_CONTRACT_INVALID'
     ) THEN
    RETURN ops.economics_import_owner_result_v1(
      'BINDING_REJECTED','ECONOMICS_IMPORT_FAILURE_BINDING_REJECTED','{}'
    );
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'ECONOMICS_IMPORT_EXECUTION:'||p_execution_id::text||':'||p_generation::text,
    0
  ));
  v_terminal:=ops.economics_import_terminal_replay_v1(
    p_job_id,p_execution_id,p_generation
  );
  IF v_terminal IS NOT NULL THEN
    IF v_terminal->>'terminalKind'='SUCCEEDED' THEN
      RETURN ops.economics_import_owner_result_v1(
        'COMPLETION_REPLAY','ECONOMICS_IMPORT_COMPLETION_REPLAYED',v_terminal
      );
    ELSIF v_terminal->>'terminalKind'='OPERATION_REJECTED' THEN
      RETURN ops.economics_import_owner_result_v1(
        'OPERATION_REJECTED','ECONOMICS_IMPORT_OPERATION_REJECTED',v_terminal
      );
    END IF;
    RETURN ops.economics_import_owner_result_v1(
      'FAILURE_REPLAY','ECONOMICS_IMPORT_FAILURE_REPLAYED',v_terminal
    );
  END IF;
  SELECT job.* INTO v_job FROM ops.jobs AS job
  WHERE job.id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN ops.economics_import_owner_result_v1(
      'BINDING_REJECTED','ECONOMICS_IMPORT_FAILURE_BINDING_REJECTED','{}'
    );
  END IF;
  v_binding_code:=ops.economics_import_execution_binding_code_v1(
    p_job_id,p_job_lease_token,p_job_fencing_token,NULL,
    p_execution_id,p_generation,NULL,NULL,v_job.lease_owner,true
  );
  IF v_binding_code IS NOT NULL THEN
    RETURN CASE v_binding_code
      WHEN 'PRODUCER_FENCE_STALE' THEN
        ops.economics_import_owner_result_v1(
          'PRODUCER_FENCE_STALE','ECONOMICS_IMPORT_PRODUCER_FENCE_STALE','{}'
        )
      WHEN 'PRODUCER_LEASE_EXPIRED' THEN
        ops.economics_import_owner_result_v1(
          'PRODUCER_LEASE_EXPIRED','ECONOMICS_IMPORT_PRODUCER_LEASE_EXPIRED','{}'
        )
      WHEN 'AUTHORIZATION_EXPIRED' THEN
        ops.economics_import_owner_result_v1(
          'AUTHORIZATION_EXPIRED','ECONOMICS_IMPORT_AUTHORIZATION_EXPIRED','{}'
        )
      WHEN 'EXECUTION_NOT_CLAIMABLE' THEN
        ops.economics_import_owner_result_v1(
          'EXECUTION_NOT_CLAIMABLE',
          'ECONOMICS_IMPORT_EXECUTION_NOT_CLAIMABLE','{}'
        )
      ELSE ops.economics_import_owner_result_v1(
        'BINDING_REJECTED','ECONOMICS_IMPORT_FAILURE_BINDING_REJECTED','{}'
      )
    END;
  END IF;
  SELECT effect.* INTO STRICT v_effect FROM ops.in_flight_effects AS effect
  WHERE effect.id=p_execution_id FOR UPDATE;
  SELECT attempt.* INTO STRICT v_attempt FROM ops.execution_attempts AS attempt
  WHERE attempt.execution_id=p_execution_id AND attempt.generation=p_generation
  FOR UPDATE;
  SELECT receipt.* INTO v_claim FROM ops.execution_receipts AS receipt
  WHERE receipt.execution_id=p_execution_id
    AND receipt.generation=p_generation
    AND receipt.receipt_sequence=v_attempt.last_receipt_sequence
    AND receipt.receipt_digest=v_attempt.last_receipt_digest
    AND receipt.receipt_kind='LEASE_CLAIMED'
  FOR SHARE;
  IF NOT FOUND OR v_effect.state<>'QUEUED'
     OR v_attempt.attempt_state<>'CLAIMED'
     OR v_attempt.lease_token<>p_job_lease_token
     OR v_attempt.lease_owner<>v_job.lease_owner
     OR v_attempt.lease_expires_at<=clock_timestamp()
     OR v_claim.receipt_payload->>'producerJobId'<>p_job_id::text
     OR v_claim.receipt_payload->>'producerJobFencingToken'
       <>p_job_fencing_token::text
     OR v_effect.last_receipt_sequence<>v_attempt.last_receipt_sequence
     OR v_effect.last_receipt_digest<>v_attempt.last_receipt_digest THEN
    RETURN ops.economics_import_owner_result_v1(
      'EXECUTION_NOT_CLAIMABLE',
      'ECONOMICS_IMPORT_EXECUTION_NOT_CLAIMABLE','{}'
    );
  END IF;
  v_terminal:=ops.terminalize_economics_import_execution_v1(
    p_job_id,p_execution_id,p_generation,p_request_id,'PERMANENT_FAILED',
    NULL,p_error_code,p_error_detail_digest,NULL
  );
  RETURN ops.economics_import_owner_result_v1(
    'FAILED','ECONOMICS_IMPORT_EXECUTION_FAILED',v_terminal
  );
END
$$;
ALTER FUNCTION ops.fail_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,bigint,text,char(64),uuid
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.fail_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,bigint,text,char(64),uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.fail_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,bigint,text,char(64),uuid
) TO gurine_economics_importer;

-- R6E_ACTION_EXECUTION_OWNER_FUNCTIONS_COMPLETE_ONLY

CREATE FUNCTION ops.complete_economics_import_execution_v1(
  p_job_id uuid,
  p_job_lease_token uuid,
  p_job_fencing_token bigint,
  p_execution_id uuid,
  p_generation bigint,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_binding_code text;
  v_job ops.jobs%ROWTYPE;
  v_auth ops.execution_authorizations%ROWTYPE;
  v_effect ops.in_flight_effects%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_detail ops.action_approval_economics_import_details%ROWTYPE;
  v_claim ops.execution_receipts%ROWTYPE;
  v_dispatch_id uuid:=gen_random_uuid();
  v_dispatch_sequence bigint;
  v_dispatch_payload jsonb;
  v_dispatch_canonical bytea;
  v_dispatch_digest char(64);
  v_dispatch_audit_id uuid;
  v_apply_receipt ops.economics_import_apply_receipt_v1;
  v_terminal jsonb;
  v_rejection_detail_digest char(64);
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_economics_importer'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'ECONOMICS_IMPORTER_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF p_job_id IS NULL OR p_job_lease_token IS NULL
     OR p_job_fencing_token IS NULL OR p_job_fencing_token<1
     OR p_execution_id IS NULL OR p_generation IS DISTINCT FROM 1
     OR p_request_id IS NULL THEN
    RETURN ops.economics_import_owner_result_v1(
      'BINDING_REJECTED','ECONOMICS_IMPORT_COMPLETION_BINDING_REJECTED','{}'
    );
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'ECONOMICS_IMPORT_EXECUTION:'||p_execution_id::text||':'||p_generation::text,
    0
  ));
  v_terminal:=ops.economics_import_terminal_replay_v1(
    p_job_id,p_execution_id,p_generation
  );
  IF v_terminal IS NOT NULL THEN
    IF v_terminal->>'terminalKind'='SUCCEEDED' THEN
      RETURN ops.economics_import_owner_result_v1(
        'COMPLETION_REPLAY','ECONOMICS_IMPORT_COMPLETION_REPLAYED',v_terminal
      );
    ELSIF v_terminal->>'terminalKind'='OPERATION_REJECTED' THEN
      RETURN ops.economics_import_owner_result_v1(
        'OPERATION_REJECTED','ECONOMICS_IMPORT_OPERATION_REJECTED',v_terminal
      );
    END IF;
    RETURN ops.economics_import_owner_result_v1(
      'FAILURE_REPLAY','ECONOMICS_IMPORT_FAILURE_REPLAYED',v_terminal
    );
  END IF;

  SELECT job.* INTO v_job FROM ops.jobs AS job
  WHERE job.id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN ops.economics_import_owner_result_v1(
      'BINDING_REJECTED','ECONOMICS_IMPORT_COMPLETION_BINDING_REJECTED','{}'
    );
  END IF;
  v_binding_code:=ops.economics_import_execution_binding_code_v1(
    p_job_id,p_job_lease_token,p_job_fencing_token,NULL,
    p_execution_id,p_generation,NULL,NULL,v_job.lease_owner,true
  );
  IF v_binding_code IS NOT NULL THEN
    RETURN CASE v_binding_code
      WHEN 'PRODUCER_FENCE_STALE' THEN
        ops.economics_import_owner_result_v1(
          'PRODUCER_FENCE_STALE','ECONOMICS_IMPORT_PRODUCER_FENCE_STALE','{}'
        )
      WHEN 'PRODUCER_LEASE_EXPIRED' THEN
        ops.economics_import_owner_result_v1(
          'PRODUCER_LEASE_EXPIRED','ECONOMICS_IMPORT_PRODUCER_LEASE_EXPIRED','{}'
        )
      WHEN 'AUTHORIZATION_EXPIRED' THEN
        ops.economics_import_owner_result_v1(
          'AUTHORIZATION_EXPIRED','ECONOMICS_IMPORT_AUTHORIZATION_EXPIRED','{}'
        )
      WHEN 'EXECUTION_NOT_CLAIMABLE' THEN
        ops.economics_import_owner_result_v1(
          'EXECUTION_NOT_CLAIMABLE',
          'ECONOMICS_IMPORT_EXECUTION_NOT_CLAIMABLE','{}'
        )
      ELSE ops.economics_import_owner_result_v1(
        'BINDING_REJECTED',
        'ECONOMICS_IMPORT_COMPLETION_BINDING_REJECTED','{}'
      )
    END;
  END IF;

  SELECT auth.* INTO STRICT v_auth FROM ops.execution_authorizations AS auth
  WHERE auth.execution_id=p_execution_id AND auth.generation=p_generation
  FOR SHARE;
  SELECT effect.* INTO STRICT v_effect FROM ops.in_flight_effects AS effect
  WHERE effect.id=p_execution_id FOR UPDATE;
  SELECT attempt.* INTO STRICT v_attempt FROM ops.execution_attempts AS attempt
  WHERE attempt.execution_id=p_execution_id AND attempt.generation=p_generation
  FOR UPDATE;
  SELECT detail.* INTO STRICT v_detail
  FROM ops.action_approval_economics_import_details AS detail
  WHERE detail.proposal_id=v_auth.proposal_id
    AND detail.proposal_version=v_auth.proposal_version
  FOR SHARE;
  SELECT receipt.* INTO v_claim FROM ops.execution_receipts AS receipt
  WHERE receipt.execution_id=p_execution_id
    AND receipt.generation=p_generation
    AND receipt.receipt_sequence=v_attempt.last_receipt_sequence
    AND receipt.receipt_digest=v_attempt.last_receipt_digest
    AND receipt.receipt_kind='LEASE_CLAIMED'
  FOR SHARE;
  IF NOT FOUND OR v_effect.state<>'QUEUED'
     OR v_attempt.attempt_state<>'CLAIMED'
     OR v_attempt.lease_token<>p_job_lease_token
     OR v_attempt.lease_owner<>v_job.lease_owner
     OR v_attempt.lease_expires_at<=v_now
     OR v_claim.receipt_payload->>'producerJobId'<>p_job_id::text
     OR v_claim.receipt_payload->>'producerJobFencingToken'
       <>p_job_fencing_token::text
     OR v_claim.receipt_payload->>'executionId'<>p_execution_id::text
     OR v_claim.receipt_payload->>'generation'<>p_generation::text
     OR v_claim.receipt_payload->>'operationId'<>v_detail.operation_id
     OR v_claim.receipt_payload->>'operationDigest'
       <>btrim(v_detail.operation_digest::text)
     OR v_effect.last_receipt_sequence<>v_attempt.last_receipt_sequence
     OR v_effect.last_receipt_digest<>v_attempt.last_receipt_digest THEN
    RETURN ops.economics_import_owner_result_v1(
      'EXECUTION_NOT_CLAIMABLE',
      'ECONOMICS_IMPORT_EXECUTION_NOT_CLAIMABLE','{}'
    );
  END IF;

  v_dispatch_sequence:=v_attempt.last_receipt_sequence+1;
  v_dispatch_payload:=jsonb_build_object(
    'schemaVersion','economics-import-dispatch-receipt.v1',
    'producerJobId',p_job_id,
    'producerJobFencingToken',p_job_fencing_token,
    'eventId',(v_job.payload->>'eventId')::uuid,
    'executionId',p_execution_id,
    'generation',p_generation,
    'attemptId',v_attempt.id,
    'executionFencingToken',v_attempt.fencing_token,
    'executionDigest',btrim(v_auth.execution_digest::text),
    'approvalDigest',btrim(v_auth.approval_digest::text),
    'actionDetailDigest',btrim(v_detail.action_detail_digest::text),
    'operationId',v_detail.operation_id,
    'operationDigest',btrim(v_detail.operation_digest::text),
    'sourceEvidenceSetDigest',
      btrim(v_detail.source_evidence_set_digest::text),
    'importPolicyDigest',btrim(v_detail.import_policy_digest::text),
    'dispatchedAt',v_now
  );
  v_dispatch_canonical:=ops.canonical_jsonb_v1(v_dispatch_payload);
  v_dispatch_digest:=encode(
    extensions.digest(v_dispatch_canonical,'sha256'),'hex'
  );
  v_dispatch_audit_id:=ops.append_audit_event(
    'workflow:economics-import:'||p_execution_id::text,
    'SERVICE','workflow-worker.economics-import-executor',NULL::uuid,
    'ECONOMICS_IMPORT_EXECUTION_DISPATCHED','ActionExecution',
    p_execution_id::text,'economics.import','SUCCESS',NULL,p_request_id,
    jsonb_build_object(
      'executionId',p_execution_id,'generation',p_generation,
      'operationId',v_detail.operation_id,
      'producerJobId',p_job_id,
      'producerJobFencingToken',p_job_fencing_token,
      'executionReceiptSequence',v_dispatch_sequence,
      'executionReceiptDigest',v_dispatch_digest
    )
  );
  INSERT INTO ops.execution_receipts(
    id,execution_id,generation,attempt_id,receipt_sequence,receipt_kind,
    mutates_aggregate_state,prior_aggregate_state,aggregate_state,
    aggregate_state_version,prior_attempt_state,attempt_state,fencing_token,
    cancellation_generation,proof_kind,proof_digest,receipt_payload,
    receipt_payload_canonical,budget_reservation_id,budget_reservation_digest,
    request_id,audit_event_id,outbox_id,observed_at,prior_receipt_digest,
    receipt_digest
  ) VALUES (
    v_dispatch_id,p_execution_id,p_generation,v_attempt.id,
    v_dispatch_sequence,'DISPATCH_STARTED',true,'QUEUED','RUNNING',
    v_effect.state_version+1,'CLAIMED','DISPATCHING',v_attempt.fencing_token,
    v_effect.cancellation_generation,'DEFINITIVE_NOT_ACCEPTED',
    v_detail.operation_digest,v_dispatch_payload,v_dispatch_canonical,
    v_auth.budget_reservation_id,v_auth.budget_reservation_digest,p_request_id,
    v_dispatch_audit_id,NULL,v_now,v_attempt.last_receipt_digest,
    v_dispatch_digest
  );
  UPDATE ops.execution_attempts SET
    attempt_state='DISPATCHING',state_version=state_version+1,
    dispatch_ordinal=1,dispatch_started_at=v_now,
    last_receipt_sequence=v_dispatch_sequence,
    last_receipt_digest=v_dispatch_digest,updated_at=v_now
  WHERE id=v_attempt.id AND state_version=v_attempt.state_version
    AND attempt_state='CLAIMED'
    AND last_receipt_sequence=v_attempt.last_receipt_sequence
    AND last_receipt_digest=v_attempt.last_receipt_digest;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'economics_import_dispatch_serialization_conflict'
      USING ERRCODE='40001';
  END IF;
  UPDATE ops.in_flight_effects SET
    state='RUNNING',state_version=state_version+1,
    last_receipt_sequence=v_dispatch_sequence,
    last_receipt_digest=v_dispatch_digest,updated_at=v_now
  WHERE id=p_execution_id AND state='QUEUED'
    AND state_version=v_effect.state_version
    AND last_receipt_sequence=v_effect.last_receipt_sequence
    AND last_receipt_digest=v_effect.last_receipt_digest;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'economics_import_effect_dispatch_serialization_conflict'
      USING ERRCODE='40001';
  END IF;

  BEGIN
    v_apply_receipt:=ops.apply_economics_import_operation_v1(
      v_detail.operation_value,p_execution_id,p_generation,
      v_auth.approval_digest
    );
  EXCEPTION WHEN SQLSTATE 'P6E10' THEN
    v_rejection_detail_digest:=encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'schemaVersion','economics-import-operation-rejection.v1',
        'executionId',p_execution_id,'generation',p_generation,
        'approvalDigest',btrim(v_auth.approval_digest::text),
        'operationId',v_detail.operation_id,
        'operationDigest',btrim(v_detail.operation_digest::text),
        'rejectionCode','ECONOMICS_IMPORT_OPERATION_REJECTED'
      )),'sha256'
    ),'hex');
    v_terminal:=ops.terminalize_economics_import_execution_v1(
      p_job_id,p_execution_id,p_generation,p_request_id,
      'OPERATION_REJECTED',NULL,'ECONOMICS_IMPORT_OPERATION_REJECTED',
      v_rejection_detail_digest,NULL
    );
    RETURN ops.economics_import_owner_result_v1(
      'OPERATION_REJECTED','ECONOMICS_IMPORT_OPERATION_REJECTED',v_terminal
    );
  END;
  IF NOT ops.economics_import_apply_receipt_v1_is_valid(v_apply_receipt)
     OR v_apply_receipt.operation_id<>v_detail.operation_id
     OR v_apply_receipt.applied_at<v_now
     OR v_apply_receipt.applied_at>clock_timestamp()+interval '5 seconds' THEN
    RAISE EXCEPTION 'economics_import_apply_receipt_invalid'
      USING ERRCODE='55000';
  END IF;
  v_terminal:=ops.terminalize_economics_import_execution_v1(
    p_job_id,p_execution_id,p_generation,p_request_id,'SUCCEEDED',
    v_apply_receipt.result_set_digest,NULL,NULL,
    v_apply_receipt.notification_outbox_event_id
  );
  RETURN ops.economics_import_owner_result_v1(
    'COMPLETED','ECONOMICS_IMPORT_EXECUTION_COMPLETED',v_terminal
  );
END
$$;
ALTER FUNCTION ops.complete_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,bigint,uuid
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.complete_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,bigint,uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.complete_economics_import_execution_v1(
  uuid,uuid,bigint,uuid,bigint,uuid
) TO gurine_economics_importer;

-- R6E_PAYMENT_OWNER_FUNCTIONS

ALTER TABLE ops.tasks
  ADD COLUMN creation_digest char(64),
  ADD COLUMN payment_review_source_kind text,
  ADD COLUMN payment_review_source_receipt_id uuid,
  ADD COLUMN payment_review_source_receipt_digest char(64),
  ADD COLUMN payment_review_reason_digest char(64),
  ADD COLUMN payment_review_notification_intent_id uuid,
  ADD COLUMN payment_review_execution_id uuid,
  ADD COLUMN payment_review_execution_generation bigint,
  ADD COLUMN payment_review_action_detail_digest char(64);
ALTER TABLE ops.tasks ADD CONSTRAINT tasks_payment_review_shape_ck CHECK (
  task_type='PAYMENT_REVIEW'
  AND creation_digest ~ '^[0-9a-f]{64}$'
  AND payment_review_source_kind IN (
    'DONATION_PAYMENT_FAILURE','SIGNED_COLLECTION_FAILURE'
  )
  AND payment_review_source_receipt_id IS NOT NULL
  AND payment_review_source_receipt_digest ~ '^[0-9a-f]{64}$'
  AND payment_review_reason_digest ~ '^[0-9a-f]{64}$'
  AND payment_review_notification_intent_id IS NOT NULL
  AND (
    payment_review_source_kind='DONATION_PAYMENT_FAILURE'
    AND payment_review_execution_id IS NULL
    AND payment_review_execution_generation IS NULL
    AND payment_review_action_detail_digest IS NULL
    OR payment_review_source_kind='SIGNED_COLLECTION_FAILURE'
    AND payment_review_execution_id IS NOT NULL
    AND payment_review_execution_generation>0
    AND payment_review_action_detail_digest ~ '^[0-9a-f]{64}$'
  )
  OR task_type<>'PAYMENT_REVIEW'
  AND creation_digest IS NULL
  AND payment_review_source_kind IS NULL
  AND payment_review_source_receipt_id IS NULL
  AND payment_review_source_receipt_digest IS NULL
  AND payment_review_reason_digest IS NULL
  AND payment_review_notification_intent_id IS NULL
  AND payment_review_execution_id IS NULL
  AND payment_review_execution_generation IS NULL
  AND payment_review_action_detail_digest IS NULL
);
CREATE UNIQUE INDEX tasks_payment_review_source_uq
  ON ops.tasks(payment_review_source_kind,payment_review_source_receipt_id)
  WHERE task_type='PAYMENT_REVIEW';
CREATE UNIQUE INDEX tasks_payment_review_intent_uq
  ON ops.tasks(payment_review_notification_intent_id)
  WHERE task_type='PAYMENT_REVIEW';

CREATE TYPE ops.r6e_donation_intent_claim_v1 AS (
  request_id uuid,
  provider text,
  merchant_account_hmac char(64),
  merchant_hmac_key_version text,
  donor_hmac char(64),
  donor_group_hmac char(64),
  donor_hmac_key_version text,
  offer_version_id uuid,
  offer_digest char(64),
  tier_id uuid,
  cadence text,
  consent_receipt_digest char(64),
  request_digest char(64),
  expected_amount_whole_krw bigint,
  provider_issue_idempotency_key_hmac char(64),
  provider_issue_idempotency_hmac_key_version text
);
CREATE TYPE ops.r6e_donation_intent_claim_receipt_v1 AS (
  disposition text,
  request_id uuid,
  donation_intent_id uuid,
  binding_id uuid,
  binding_digest char(64),
  binding_state text,
  job_id uuid,
  amount_whole_krw bigint,
  provider_issue_idempotency_key_hmac char(64),
  provider_issue_idempotency_hmac_key_version text,
  claim_digest char(64),
  queued_receipt_digest char(64),
  audit_event_id uuid
);
CREATE TYPE ops.r6e_payment_method_binding_complete_v1 AS (
  request_id uuid,
  request_digest char(64),
  donation_intent_id uuid,
  binding_id uuid,
  claim_digest char(64),
  provider text,
  provider_issue_idempotency_key_hmac char(64),
  billing_key_secret_reference text,
  billing_key_hmac char(64),
  billing_key_hmac_key_version text,
  credential_use_policy text,
  provider_request_digest char(64),
  provider_response_digest char(64),
  provider_http_status integer,
  completion_request_digest char(64)
);
CREATE TYPE ops.r6e_payment_method_binding_receipt_v1 AS (
  disposition text,
  request_id uuid,
  donation_intent_id uuid,
  binding_id uuid,
  active_binding_id uuid,
  active_binding_digest char(64),
  job_id uuid,
  status text,
  queued_receipt_digest char(64),
  audit_event_id uuid
);
CREATE TYPE ops.r6e_donation_intent_fail_v1 AS (
  request_id uuid,
  request_digest char(64),
  donation_intent_id uuid,
  binding_id uuid,
  claim_digest char(64),
  safe_code text,
  failure_evidence_digest char(64)
);
CREATE TYPE ops.r6e_payment_transition_receipt_v1 AS (
  disposition text,
  root_id uuid,
  row_id uuid,
  state text,
  record_digest char(64),
  audit_event_id uuid
);
CREATE TYPE ops.r6e_donation_charge_claim_v1 AS (
  job_id uuid,
  worker_id text,
  job_lease_token uuid,
  job_fencing_token bigint,
  job_binding_digest char(64),
  provider_idempotency_key_hmac char(64),
  provider_idempotency_hmac_key_version text,
  merchant_order_id_hmac char(64),
  merchant_order_hmac_key_version text,
  merchant_order_id_digest char(64),
  expected_provider_payment_id_digest char(64)
);
CREATE TYPE ops.r6e_donation_charge_job_claim_v1 AS (
  worker_id text,
  lease_seconds integer
);
CREATE TYPE ops.r6e_donation_charge_job_claim_receipt_v1 AS (
  disposition text,
  job_id uuid,
  job_type text,
  queue text,
  payload jsonb,
  provider text,
  amount_whole_krw bigint,
  attempt integer,
  max_attempts integer,
  lease_token uuid,
  fencing_token bigint,
  lease_expires_at timestamptz,
  job_binding_digest char(64)
);
CREATE TYPE ops.r6e_donation_charge_claim_receipt_v1 AS (
  disposition text,
  attempt_id uuid,
  attempt_digest char(64),
  attempt_state text,
  terminal_authority text,
  producer_operation_id text,
  provider text,
  provider_idempotency_key_hmac char(64),
  provider_idempotency_hmac_key_version text,
  merchant_order_id_hmac char(64),
  merchant_order_hmac_key_version text,
  merchant_order_id_digest char(64),
  expected_provider_payment_id_digest char(64),
  amount_whole_krw bigint,
  credential_use_policy text,
  billing_key_secret_reference text,
  billing_key_hmac char(64),
  billing_key_hmac_key_version text,
  payment_method_binding_root_id uuid,
  payment_method_binding_id uuid,
  payment_method_binding_digest char(64),
  logical_charge_id uuid,
  charge_idempotency_key_sha256 char(64),
  job_binding_digest char(64),
  claim_digest char(64),
  terminal_receipt_digest char(64),
  donation_fact_id uuid,
  donation_fact_root_id uuid,
  donation_fact_revision bigint,
  donation_fact_effect text,
  donation_fact_digest char(64),
  donation_charge_attempt_digest char(64),
  donation_provider_fetch_digest char(64),
  donation_occurred_at timestamptz,
  donation_outbox_event_id uuid,
  review_task_id uuid,
  review_task_version bigint,
  review_task_digest char(64),
  review_source_kind text,
  review_source_receipt_id uuid,
  review_source_receipt_digest char(64),
  review_occurred_at timestamptz,
  review_notification_intent_id uuid,
  review_outbox_event_id uuid,
  audit_event_id uuid
);
CREATE TYPE ops.r6e_payment_observation_v1 AS (
  provider text,
  provider_payment_id_digest char(64),
  merchant_order_id_digest char(64),
  attempt_id uuid,
  amount_whole_krw bigint,
  payment_state text,
  provider_observed_at timestamptz,
  transport_request_digest char(64),
  transport_response_digest char(64),
  provider_fetch_digest char(64),
  fixture_authority text,
  test_payment_outcome_config_digest char(64)
);
CREATE TYPE ops.r6e_donation_charge_complete_v1 AS (
  attempt_id uuid,
  claim_digest char(64),
  observation ops.r6e_payment_observation_v1,
  completion_request_digest char(64)
);
CREATE TYPE ops.r6e_donation_charge_accept_v1 AS (
  attempt_id uuid,
  claim_digest char(64),
  provider_payment_id_digest char(64),
  transport_request_digest char(64),
  transport_response_digest char(64),
  fixture_authority text,
  test_payment_outcome_config_digest char(64),
  completion_request_digest char(64)
);
CREATE TYPE ops.r6e_donation_charge_fail_v1 AS (
  attempt_id uuid,
  claim_digest char(64),
  safe_code text,
  failure_evidence_digest char(64),
  completion_request_digest char(64)
);
CREATE TYPE ops.r6e_donation_charge_terminal_receipt_v1 AS (
  disposition text,
  attempt_id uuid,
  state text,
  terminal_authority text,
  producer_operation_id text,
  receipt_digest char(64),
  fixture_authority text,
  test_payment_outcome_config_digest char(64),
  effects text,
  donation_fact_id uuid,
  donation_fact_root_id uuid,
  donation_fact_revision bigint,
  donation_fact_effect text,
  donation_fact_digest char(64),
  charge_attempt_digest char(64),
  provider_fetch_digest char(64),
  donation_occurred_at timestamptz,
  donation_outbox_event_id uuid,
  review_task_id uuid,
  review_task_version bigint,
  review_task_digest char(64),
  review_source_kind text,
  review_source_receipt_id uuid,
  review_source_receipt_digest char(64),
  review_occurred_at timestamptz,
  review_notification_intent_id uuid,
  review_outbox_event_id uuid,
  audit_event_id uuid
);
CREATE TYPE ops.r6e_charge_reconciliation_v1 AS (
  attempt_id uuid,
  claim_digest char(64),
  reason text,
  evidence_digest char(64)
);
CREATE TYPE ops.r6e_provider_webhook_claim_v1 AS (
  provider text,
  event_identity_digest char(64),
  locator_kind text,
  locator_digest char(64),
  body_digest char(64),
  hint_digest char(64),
  authentication_state text,
  signature_digest char(64),
  signed_payload_digest char(64),
  claim_request_digest char(64)
);
CREATE TYPE ops.r6e_provider_webhook_claim_receipt_v1 AS (
  disposition text,
  provider text,
  event_identity_digest char(64),
  claim_id uuid,
  claim_digest char(64),
  attempt_id uuid,
  attempt_digest char(64),
  logical_charge_id uuid,
  job_binding_digest char(64),
  charge_idempotency_key_sha256 char(64),
  merchant_order_id_digest char(64),
  amount_whole_krw bigint,
  webhook_receipt_digest char(64),
  audit_event_id uuid
);
CREATE TYPE ops.r6e_provider_webhook_complete_v1 AS (
  provider text,
  event_identity_digest char(64),
  claim_id uuid,
  claim_digest char(64),
  observation ops.r6e_payment_observation_v1,
  completion_request_digest char(64)
);
CREATE TYPE ops.r6e_provider_webhook_receipt_v1 AS (
  disposition text,
  provider text,
  event_identity_digest char(64),
  receipt_digest char(64),
  resulting_charge_attempt_id uuid,
  resulting_charge_attempt_digest char(64),
  resulting_donation_fact_id uuid,
  resulting_donation_fact_digest char(64),
  donation_outbox_event_id uuid,
  review_notification_intent_id uuid,
  review_outbox_event_id uuid,
  audit_event_id uuid
);
CREATE TYPE ops.r6e_provider_webhook_release_v1 AS (
  provider text,
  event_identity_digest char(64),
  claim_id uuid,
  claim_digest char(64),
  safe_code text,
  release_evidence_digest char(64)
);
CREATE TYPE ops.r6e_payment_review_task_create_v1 AS (
  source_kind text,
  source_receipt_id uuid,
  source_receipt_digest char(64),
  reason_digest char(64),
  assignee_user_id uuid,
  due_at timestamptz,
  occurred_at timestamptz,
  execution_id uuid,
  execution_generation bigint,
  action_detail_digest char(64)
);
CREATE TYPE ops.r6e_payment_review_task_receipt_v1 AS (
  review_task_id uuid,
  review_task_version bigint,
  review_task_digest char(64),
  source_kind text,
  source_receipt_id uuid,
  source_receipt_digest char(64),
  occurred_at timestamptz,
  notification_intent_id uuid,
  intent_digest char(64),
  outbox_event_id uuid,
  audit_event_id uuid,
  idempotency_replay boolean
);
CREATE TYPE ops.r6e_payment_review_authority_v1 AS (
  assignee_user_id uuid,
  subject_id uuid,
  authorization_event_id uuid,
  authorization_receipt_digest char(64),
  policy_version text,
  policy_digest char(64),
  subject_origin_binding_digest char(64)
);
CREATE TYPE ops.payment_review_notification_materialize_v1 AS (
  event_id uuid,
  review_task_id uuid,
  review_task_version bigint,
  review_task_digest char(64),
  source_kind text,
  source_receipt_id uuid,
  source_receipt_digest char(64),
  occurred_at timestamptz
);
CREATE TYPE ops.payment_review_notification_materialize_receipt_v1 AS (
  event_id uuid,
  review_task_id uuid,
  review_task_version bigint,
  review_task_digest char(64),
  source_kind text,
  source_receipt_id uuid,
  source_receipt_digest char(64),
  occurred_at timestamptz,
  intent_id uuid,
  intent_digest char(64),
  prior_intent_version bigint,
  intent_version bigint,
  intent_state text,
  transition_receipt_digest char(64),
  audit_event_id uuid,
  outbox_event_id uuid,
  idempotency_replay boolean
);
CREATE FUNCTION ops.r6e_payment_sha256_jsonb_v1(p_value jsonb)
RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(p_value),'sha256'),'hex')::char(64)
$$;

CREATE FUNCTION ops.r6e_test_donation_tier_amount_v1(
  p_offer_version_id uuid,
  p_offer_digest char(64),
  p_tier_id uuid
) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
  SELECT CASE
    WHEN p_offer_version_id='00000000-0000-4000-8000-0000000006e1'::uuid
     AND btrim(p_offer_digest)='cf18751cc0841e31573e00f02cbfc0b780ec8428a60cb691214ecb87193d5b5c'
    THEN CASE p_tier_id
      WHEN '00000000-0000-4000-8000-0000000006e2'::uuid THEN 1000
      WHEN '00000000-0000-4000-8000-0000000006e3'::uuid THEN 5000
      WHEN '00000000-0000-4000-8000-0000000006e4'::uuid THEN 10000
      ELSE NULL
    END
    ELSE NULL
  END
$$;

REVOKE ALL ON FUNCTION ops.r6e_payment_sha256_jsonb_v1(jsonb),
  ops.r6e_test_donation_tier_amount_v1(uuid,char(64),uuid) FROM PUBLIC;

-- RLS-owned communication authority is resolved by the migration owner.  The
-- payment writer receives this one closed lookup only; neither it nor a
-- runtime principal receives SELECT on intake communication relations.
CREATE FUNCTION ops.resolve_r6e_payment_review_authority_v1(
  p_assignee_user_id uuid
) RETURNS ops.r6e_payment_review_authority_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,pg_temp
AS $$
DECLARE
  v_subject intake.communication_subjects%ROWTYPE;
  v_authorization intake.communication_authorization_events%ROWTYPE;
BEGIN
  IF session_user NOT IN (
       'gurine_billing_gateway','gurine_economics_importer',
       'gurine_notification_worker'
     )
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_AUTHORITY_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_assignee_user_id IS NULL THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_ASSIGNEE_REQUIRED'
      USING ERRCODE='22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM ops.users u WHERE u.id=p_assignee_user_id
      AND u.status='ACTIVE'
  ) THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_ASSIGNEE_NOT_ACTIVE'
      USING ERRCODE='P0002';
  END IF;
  SELECT s.* INTO v_subject
  FROM intake.communication_subjects s
  JOIN ops.users u ON u.id=s.origin_object_id AND u.status='ACTIVE'
  WHERE s.subject_kind='INTERNAL_USER'
    AND s.origin_object_type='INTERNAL_USER'
    AND s.origin_object_id=p_assignee_user_id
    AND s.status='ACTIVE'
  ORDER BY s.id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_SUBJECT_NOT_ACTIVE'
      USING ERRCODE='P0002';
  END IF;
  SELECT a.* INTO v_authorization
  FROM intake.communication_authorization_events a
  WHERE a.subject_id=v_subject.id
    AND a.subject_origin_binding_digest=v_subject.origin_binding_digest
    AND a.purpose='INTERNAL_ACTION_REQUEST'
    AND a.change_kind IN ('GRANTED','RESTORED')
    AND a.effective_at<=clock_timestamp()
    AND (a.expires_at IS NULL OR a.expires_at>clock_timestamp())
    AND NOT EXISTS (
      SELECT 1
      FROM intake.communication_authorization_events later
      WHERE later.subject_id=a.subject_id
        AND later.endpoint_id=a.endpoint_id
        AND later.purpose=a.purpose
        AND later.topic_scope_digest=a.topic_scope_digest
        AND later.authorization_sequence>a.authorization_sequence
    )
  ORDER BY a.effective_at DESC,a.authorization_sequence DESC,a.id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_AUTHORIZATION_NOT_CURRENT'
      USING ERRCODE='55000';
  END IF;
  RETURN (
    v_subject.origin_object_id,v_subject.id,v_authorization.id,
    v_authorization.receipt_digest,
    v_authorization.policy_version,v_authorization.policy_digest,
    v_subject.origin_binding_digest
  )::ops.r6e_payment_review_authority_v1;
END
$$;
ALTER FUNCTION ops.resolve_r6e_payment_review_authority_v1(uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.resolve_r6e_payment_review_authority_v1(uuid) FROM PUBLIC;

CREATE FUNCTION ops.r6e_payment_review_source_is_authoritative_v1(
  p_source_kind text,
  p_source_receipt_id uuid,
  p_source_receipt_digest char(64)
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
  SELECT CASE p_source_kind
    WHEN 'DONATION_PAYMENT_FAILURE' THEN EXISTS (
      SELECT 1 FROM ops.payment_charge_attempts attempt
      WHERE attempt.root_attempt_id=p_source_receipt_id
        AND attempt.record_digest=p_source_receipt_digest
        AND attempt.attempt_state='FAILED'
        AND attempt.terminal_authority='PROVIDER_FETCH_CONFIRMED'
        AND attempt.provider_observed_state IN ('FAILED','CANCELED')
        AND attempt.provider_fetch_digest IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM ops.payment_charge_attempts later
          WHERE later.root_attempt_id=attempt.root_attempt_id
            AND later.observation_version>attempt.observation_version
        )
    )
    ELSE false
  END
$$;
ALTER FUNCTION ops.r6e_payment_review_source_is_authoritative_v1(
  text,uuid,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6e_payment_review_source_is_authoritative_v1(
  text,uuid,char(64)
) FROM PUBLIC;

CREATE FUNCTION ops.create_r6e_payment_review_task_core_v1(
  p ops.r6e_payment_review_task_create_v1
) RETURNS ops.r6e_payment_review_task_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $$
DECLARE
  v_existing ops.tasks%ROWTYPE;
  v_authority ops.r6e_payment_review_authority_v1;
  v_task_id uuid:=gen_random_uuid();
  v_intent_id uuid:=gen_random_uuid();
  v_event_id uuid;
  v_audit_id uuid;
  v_task_digest char(64);
  v_topic_scope jsonb;
  v_topic_digest char(64);
  v_intent_digest char(64);
  v_policy_snapshot_digest char(64);
BEGIN
  IF session_user NOT IN (
       'gurine_billing_gateway','gurine_economics_importer'
     )
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_TASK_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF (p).source_kind NOT IN (
       'DONATION_PAYMENT_FAILURE','SIGNED_COLLECTION_FAILURE'
     )
     OR (p).source_receipt_id IS NULL
     OR (p).source_receipt_digest !~ '^[0-9a-f]{64}$'
     OR (p).reason_digest !~ '^[0-9a-f]{64}$'
     OR (p).assignee_user_id IS NULL
     OR (p).occurred_at IS NULL
     OR (p).due_at IS NULL OR (p).due_at<=(p).occurred_at
     OR ((p).source_kind='DONATION_PAYMENT_FAILURE' AND num_nonnulls(
       (p).execution_id,(p).execution_generation,(p).action_detail_digest
     )<>0)
     OR ((p).source_kind='SIGNED_COLLECTION_FAILURE' AND (
       (p).execution_id IS NULL OR (p).execution_generation IS NULL
       OR (p).execution_generation<1
       OR (p).action_detail_digest !~ '^[0-9a-f]{64}$'
     )) THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_TASK_INPUT_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing
  FROM ops.tasks
  WHERE task_type='PAYMENT_REVIEW'
    AND payment_review_source_kind=(p).source_kind
    AND payment_review_source_receipt_id=(p).source_receipt_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.payment_review_source_receipt_digest
         IS DISTINCT FROM (p).source_receipt_digest
       OR v_existing.payment_review_reason_digest
         IS DISTINCT FROM (p).reason_digest
       OR v_existing.assignee_user_id IS DISTINCT FROM (p).assignee_user_id
       OR v_existing.due_at IS DISTINCT FROM (p).due_at
       OR v_existing.created_at IS DISTINCT FROM (p).occurred_at
       OR v_existing.payment_review_execution_id IS DISTINCT FROM
         (p).execution_id
       OR v_existing.payment_review_execution_generation IS DISTINCT FROM
         (p).execution_generation
       OR v_existing.payment_review_action_detail_digest IS DISTINCT FROM
         (p).action_detail_digest
       OR v_existing.creation_digest IS DISTINCT FROM
         ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
           'schemaVersion','r6e-payment-review-task.v1',
           'assigneeUserId',v_existing.assignee_user_id,
           'dueAt',v_existing.due_at,'occurredAt',v_existing.created_at,
           'reasonDigest',btrim(v_existing.payment_review_reason_digest),
           'reviewTaskId',v_existing.id,
           'sourceKind',v_existing.payment_review_source_kind,
           'sourceReceiptDigest',
             btrim(v_existing.payment_review_source_receipt_digest),
           'sourceReceiptId',v_existing.payment_review_source_receipt_id,
           'executionId',v_existing.payment_review_execution_id,
           'executionGeneration',
             v_existing.payment_review_execution_generation,
           'actionDetailDigest',CASE
             WHEN v_existing.payment_review_action_detail_digest IS NULL
             THEN NULL ELSE btrim(
               v_existing.payment_review_action_detail_digest
             ) END,
           'version',v_existing.version
         )) THEN
      RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_TASK_CONFLICT'
        USING ERRCODE='23514';
    END IF;
    RETURN (
      v_existing.id,v_existing.version,v_existing.creation_digest,
      v_existing.payment_review_source_kind,
      v_existing.payment_review_source_receipt_id,
      v_existing.payment_review_source_receipt_digest,
      v_existing.created_at,
      v_existing.payment_review_notification_intent_id,
      (SELECT i.intent_digest FROM ops.communication_intents i
       WHERE i.id=v_existing.payment_review_notification_intent_id),
      (SELECT o.id FROM ops.outbox o
       WHERE o.aggregate_type='payment_review_task'
         AND o.aggregate_id=v_existing.id::text
         AND o.aggregate_version=v_existing.version
         AND o.event_type='notification.payment_review_requested.v1'),
      NULL,true
    )::ops.r6e_payment_review_task_receipt_v1;
  END IF;
  v_authority:=ops.resolve_r6e_payment_review_authority_v1(
    (p).assignee_user_id
  );
  v_task_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-payment-review-task.v1',
    'assigneeUserId',(p).assignee_user_id,
    'dueAt',(p).due_at,
    'occurredAt',(p).occurred_at,
    'reasonDigest',btrim((p).reason_digest),
    'reviewTaskId',v_task_id,
    'sourceKind',(p).source_kind,
    'sourceReceiptDigest',btrim((p).source_receipt_digest),
    'sourceReceiptId',(p).source_receipt_id,
    'executionId',(p).execution_id,
    'executionGeneration',(p).execution_generation,
    'actionDetailDigest',CASE WHEN (p).action_detail_digest IS NULL THEN NULL
      ELSE btrim((p).action_detail_digest) END,
    'version',1
  ));
  v_topic_scope:=jsonb_build_object(
    'reviewTaskId',v_task_id,'sourceKind',(p).source_kind
  );
  v_topic_digest:=ops.communication_topic_scope_digest(v_topic_scope);
  v_policy_snapshot_digest:=ops.r6e_payment_sha256_jsonb_v1(
    jsonb_build_object(
      'authorizationEventId',(v_authority).authorization_event_id,
      'authorizationReceiptDigest',
        btrim((v_authority).authorization_receipt_digest),
      'policyDigest',btrim((v_authority).policy_digest),
      'policyVersion',(v_authority).policy_version,
      'subjectOriginBindingDigest',
        btrim((v_authority).subject_origin_binding_digest)
    )
  );
  v_intent_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'intentId',v_intent_id,'reviewTaskDigest',btrim(v_task_digest),
    'reviewTaskId',v_task_id,'topicScopeDigest',btrim(v_topic_digest),
    'recipientSubjectId',(v_authority).subject_id,
    'sourceDecisionDigest',
      btrim((v_authority).authorization_receipt_digest)
  ));
  INSERT INTO ops.tasks(
    id,task_type,object_type,object_id,title,status,priority,
    assignee_user_id,due_at,version,created_at,updated_at,creation_digest,
    payment_review_source_kind,payment_review_source_receipt_id,
    payment_review_source_receipt_digest,payment_review_reason_digest,
    payment_review_notification_intent_id,payment_review_execution_id,
    payment_review_execution_generation,payment_review_action_detail_digest
  ) VALUES (
    v_task_id,'PAYMENT_REVIEW','PAYMENT_RECEIPT',(p).source_receipt_id,
    '결제 실패 운영자 검토','OPEN','HIGH',(p).assignee_user_id,(p).due_at,
    1,(p).occurred_at,(p).occurred_at,v_task_digest,(p).source_kind,
    (p).source_receipt_id,(p).source_receipt_digest,(p).reason_digest,
    v_intent_id,(p).execution_id,(p).execution_generation,
    (p).action_detail_digest
  );
  v_audit_id:=ops.append_audit_event(
    'payment-review-task:'||v_task_id::text,'SERVICE',current_user,NULL,
    'R6E_PAYMENT_REVIEW_TASK_CREATED','PaymentReviewTask',v_task_id::text,
    'payments.review','SUCCESS','human review required',gen_random_uuid(),
    jsonb_build_object(
      'reviewTaskDigest',btrim(v_task_digest),
      'sourceKind',(p).source_kind,
      'sourceReceiptDigest',btrim((p).source_receipt_digest),
      'sourceReceiptId',(p).source_receipt_id
    )
  );
  v_event_id:=ops.enqueue_outbox(
    'payment_review_task',v_task_id::text,1,
    'notification.payment_review_requested.v1',
    jsonb_build_object(
      'reviewTaskId',v_task_id,
      'reviewTaskVersion',1,
      'reviewTaskDigest',btrim(v_task_digest),
      'sourceKind',(p).source_kind,
      'sourceReceiptId',(p).source_receipt_id,
      'sourceReceiptDigest',btrim((p).source_receipt_digest),
      'occurredAt',(p).occurred_at
    ),(p).occurred_at
  );
  INSERT INTO ops.communication_intents(
    id,deployment_id,logical_intent_digest,source_event_id,
    source_event_type,source_object_type,source_object_id,
    material_event_version,communication_class,purpose,topic_scope,
    topic_scope_digest,recipient_subject_id,audience_policy_version,
    audience_policy_digest,policy_snapshot_digest,effect_safety_class,
    source_decision_receipt_id,source_decision_digest,state,version,
    intent_digest,creation_receipt_digest,created_at,state_changed_at
  ) VALUES (
    v_intent_id,'r6e-test-fixture',v_intent_digest,v_event_id,
    'notification.payment_review_requested.v1','PAYMENT_REVIEW_TASK',
    v_task_id,1,'INTERNAL_ACTION_REQUEST','INTERNAL_ACTION_REQUEST',
    v_topic_scope,v_topic_digest,(v_authority).subject_id,
    (v_authority).policy_version,(v_authority).policy_digest,
    v_policy_snapshot_digest,'DUPLICATION_SENSITIVE',
    (v_authority).authorization_event_id,
    (v_authority).authorization_receipt_digest,'CREATED',1,
    v_intent_digest,ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
      'intentDigest',btrim(v_intent_digest),'sourceEventId',v_event_id,
      'version',1
    )),(p).occurred_at,(p).occurred_at
  );
  RETURN (
    v_task_id,1,v_task_digest,(p).source_kind,(p).source_receipt_id,
    (p).source_receipt_digest,(p).occurred_at,v_intent_id,v_intent_digest,
    v_event_id,v_audit_id,false
  )::ops.r6e_payment_review_task_receipt_v1;
END
$$;

CREATE FUNCTION ops.create_r6e_payment_review_task_v1(
  p ops.r6e_payment_review_task_create_v1
) RETURNS ops.r6e_payment_review_task_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_TASK_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p IS NULL OR (p).source_kind<>'DONATION_PAYMENT_FAILURE'
     OR num_nonnulls(
       (p).execution_id,(p).execution_generation,(p).action_detail_digest
     )<>0 OR NOT ops.r6e_payment_review_source_is_authoritative_v1(
       (p).source_kind,(p).source_receipt_id,(p).source_receipt_digest
     ) THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_SOURCE_NOT_AUTHORITATIVE'
      USING ERRCODE='23514';
  END IF;
  RETURN ops.create_r6e_payment_review_task_core_v1(p);
END
$$;

CREATE FUNCTION ops.claim_r6e_donation_intent_v1(
  p ops.r6e_donation_intent_claim_v1
) RETURNS ops.r6e_donation_intent_claim_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_existing ops.payment_method_bindings%ROWTYPE;
  v_amount bigint;
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_intent_id uuid:=gen_random_uuid();
  v_binding_id uuid:=gen_random_uuid();
  v_job_id uuid:=gen_random_uuid();
  v_schedule_kind text;
  v_credential_policy text;
  v_schedule_digest char(64);
  v_mandate_digest char(64);
  v_claim_digest char(64);
  v_record_digest char(64);
  v_audit_id uuid;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  v_amount:=ops.r6e_test_donation_tier_amount_v1(
    (p).offer_version_id,(p).offer_digest,(p).tier_id
  );
  IF (p).request_id IS NULL OR (p).provider NOT IN (
       'TOSS_PAYMENTS','KAKAO_PAY','STRIPE'
     )
     OR (p).merchant_account_hmac !~ '^[0-9a-f]{64}$'
     OR (p).merchant_hmac_key_version !~ '^sha256:[0-9a-f]{16}$'
     OR (p).donor_hmac !~ '^[0-9a-f]{64}$'
     OR (p).donor_group_hmac !~ '^[0-9a-f]{64}$'
     OR (p).donor_hmac_key_version !~ '^sha256:[0-9a-f]{16}$'
     OR (p).offer_digest !~ '^[0-9a-f]{64}$'
     OR (p).cadence NOT IN ('ONE_TIME','RECURRING')
     OR (p).consent_receipt_digest !~ '^[0-9a-f]{64}$'
     OR (p).request_digest !~ '^[0-9a-f]{64}$'
     OR (p).provider_issue_idempotency_key_hmac !~ '^[0-9a-f]{64}$'
     OR (p).provider_issue_idempotency_hmac_key_version
       !~ '^sha256:[0-9a-f]{16}$'
     OR v_amount IS NULL OR (p).expected_amount_whole_krw<>v_amount
     OR (p).request_digest IS DISTINCT FROM
       ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
         'schemaVersion','r6e-donation-intent-claim.v1',
         'requestId',(p).request_id,'provider',(p).provider,
         'merchantAccountHmac',btrim((p).merchant_account_hmac),
         'merchantHmacKeyVersion',(p).merchant_hmac_key_version,
         'donorHmac',btrim((p).donor_hmac),
         'donorGroupHmac',btrim((p).donor_group_hmac),
         'donorHmacKeyVersion',(p).donor_hmac_key_version,
         'offerVersionId',(p).offer_version_id,
         'offerDigest',btrim((p).offer_digest),'tierId',(p).tier_id,
         'cadence',(p).cadence,
         'consentReceiptDigest',btrim((p).consent_receipt_digest),
         'expectedAmountWholeKrw',(p).expected_amount_whole_krw,
         'providerIssueIdempotencyKeyHmac',
           btrim((p).provider_issue_idempotency_key_hmac),
         'providerIssueIdempotencyHmacKeyVersion',
           (p).provider_issue_idempotency_hmac_key_version
       )) THEN
    RAISE EXCEPTION 'R6E_DONATION_INTENT_CLAIM_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing
  FROM ops.payment_method_bindings
  WHERE request_id=(p).request_id
  ORDER BY revision DESC
  LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_digest IS DISTINCT FROM (p).request_digest
       OR v_existing.provider IS DISTINCT FROM (p).provider
       OR v_existing.merchant_account_hmac
         IS DISTINCT FROM (p).merchant_account_hmac
       OR v_existing.donor_hmac IS DISTINCT FROM (p).donor_hmac
       OR v_existing.donor_group_hmac IS DISTINCT FROM (p).donor_group_hmac
       OR v_existing.offer_version_id IS DISTINCT FROM (p).offer_version_id
       OR v_existing.offer_digest IS DISTINCT FROM (p).offer_digest
       OR v_existing.tier_id IS DISTINCT FROM (p).tier_id
       OR v_existing.consent_receipt_digest
         IS DISTINCT FROM (p).consent_receipt_digest
       OR v_existing.mandate_amount IS DISTINCT FROM v_amount::numeric
       OR v_existing.provider_issue_idempotency_key_hmac
         IS DISTINCT FROM (p).provider_issue_idempotency_key_hmac THEN
      RETURN (
        'CONFLICT',(p).request_id,v_existing.donation_intent_id,
        v_existing.root_binding_id,v_existing.record_digest,
        v_existing.binding_state,v_existing.queued_job_id,
        v_existing.mandate_amount::bigint,
        v_existing.provider_issue_idempotency_key_hmac,
        v_existing.provider_issue_idempotency_hmac_key_version,
        v_existing.claim_digest,v_existing.queued_receipt_digest,NULL
      )::ops.r6e_donation_intent_claim_receipt_v1;
    END IF;
    RETURN (
      CASE v_existing.binding_state
        WHEN 'ACTIVE' THEN 'REPLAY'
        WHEN 'PENDING_PROVIDER' THEN 'IN_PROGRESS'
        ELSE 'CONFLICT'
      END,
      (p).request_id,v_existing.donation_intent_id,
      v_existing.root_binding_id,v_existing.record_digest,
      v_existing.binding_state,
      COALESCE(v_existing.queued_job_id,v_existing.reserved_job_id),
      v_existing.mandate_amount::bigint,
      v_existing.provider_issue_idempotency_key_hmac,
      v_existing.provider_issue_idempotency_hmac_key_version,
      v_existing.claim_digest,v_existing.queued_receipt_digest,NULL
    )::ops.r6e_donation_intent_claim_receipt_v1;
  END IF;
  v_schedule_kind:=CASE (p).cadence
    WHEN 'ONE_TIME' THEN 'ONE_TIME' ELSE 'MONTHLY' END;
  v_credential_policy:=CASE (p).cadence
    WHEN 'ONE_TIME' THEN 'SINGLE_CHARGE' ELSE 'RECURRING' END;
  v_schedule_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'firstChargeAt',v_now,'scheduleId',v_intent_id,
    'scheduleKind',v_schedule_kind,'scheduleVersion',1
  ));
  v_mandate_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'amountWholeKrw',v_amount,'consentReceiptDigest',
      btrim((p).consent_receipt_digest),
    'credentialUsePolicy',v_credential_policy,'currency','KRW',
    'donationIntentId',v_intent_id
  ));
  v_claim_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'bindingId',v_binding_id,'donationIntentId',v_intent_id,
    'mandateDigest',btrim(v_mandate_digest),
    'provider',(p).provider,'providerIssueIdempotencyKeyHmac',
      btrim((p).provider_issue_idempotency_key_hmac),
    'requestDigest',btrim((p).request_digest),'requestId',(p).request_id,
    'reservedJobId',v_job_id,'scheduleDigest',btrim(v_schedule_digest)
  ));
  v_record_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'bindingEffect','ORIGINAL','bindingId',v_binding_id,
    'bindingState','PENDING_PROVIDER','claimDigest',btrim(v_claim_digest),
    'donationIntentId',v_intent_id,'revision',1,
    'requestDigest',btrim((p).request_digest),'requestId',(p).request_id
  ));
  v_audit_id:=ops.append_audit_event(
    'payment-binding:'||v_binding_id::text,'SERVICE',current_user,NULL,
    'R6E_DONATION_INTENT_CLAIMED','PaymentMethodBinding',v_binding_id::text,
    'payments.fixture','SUCCESS','provider issuance claimed',(p).request_id,
    jsonb_build_object('claimDigest',btrim(v_claim_digest),
      'recordDigest',btrim(v_record_digest),'fixtureAuthority',
      'TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY')
  );
  INSERT INTO ops.payment_method_bindings(
    id,root_binding_id,revision,binding_effect,supersedes_binding_id,
    predecessor_record_digest,donation_intent_id,request_id,request_digest,
    deployment_id,environment,fixture_authority,provider,
    merchant_account_hmac,merchant_hmac_key_version,donor_hmac,
    donor_group_hmac,donor_hmac_key_version,
    provider_issue_idempotency_key_hmac,
    provider_issue_idempotency_hmac_key_version,reserved_job_id,
    billing_key_secret_reference,billing_key_hmac,billing_key_hmac_key_version,
    credential_use_policy,schedule_kind,schedule_id,schedule_version,
    schedule_digest,offer_version_id,offer_digest,tier_id,first_charge_at,
    mandate_amount,currency,consent_receipt_digest,mandate_digest,
    binding_state,claim_digest,provider_issue_request_digest,
    provider_issue_response_digest,provider_issue_http_status,
    completion_request_digest,queued_job_id,queued_receipt_digest,failure_code,
    failure_evidence_digest,claimed_at,bound_at,revoked_at,terminal_at,
    audit_event_id,record_digest,recorded_at
  ) VALUES (
    v_binding_id,v_binding_id,1,'ORIGINAL',NULL,NULL,v_intent_id,
    (p).request_id,(p).request_digest,
    '00000000-0000-4000-8000-0000000006e0'::uuid,'TEST',
    'TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY',(p).provider,
    (p).merchant_account_hmac,(p).merchant_hmac_key_version,(p).donor_hmac,
    (p).donor_group_hmac,(p).donor_hmac_key_version,
    (p).provider_issue_idempotency_key_hmac,
    (p).provider_issue_idempotency_hmac_key_version,v_job_id,
    NULL,NULL,NULL,v_credential_policy,v_schedule_kind,v_intent_id,1,
    v_schedule_digest,(p).offer_version_id,(p).offer_digest,(p).tier_id,v_now,
    v_amount,'KRW',(p).consent_receipt_digest,v_mandate_digest,
    'PENDING_PROVIDER',v_claim_digest,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
    v_now,NULL,NULL,NULL,v_audit_id,v_record_digest,v_now
  );
  RETURN (
    'EXECUTE',(p).request_id,v_intent_id,v_binding_id,v_record_digest,
    'PENDING_PROVIDER',v_job_id,v_amount,
    (p).provider_issue_idempotency_key_hmac,
    (p).provider_issue_idempotency_hmac_key_version,
    v_claim_digest,NULL,v_audit_id
  )::ops.r6e_donation_intent_claim_receipt_v1;
END
$$;

CREATE FUNCTION ops.complete_r6e_payment_method_binding_v1(
  p ops.r6e_payment_method_binding_complete_v1
) RETURNS ops.r6e_payment_method_binding_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_head ops.payment_method_bindings%ROWTYPE;
  v_active_id uuid:=gen_random_uuid();
  v_logical_charge_id uuid:=gen_random_uuid();
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_scheduled_for text;
  v_charge_idempotency_digest char(64);
  v_payload jsonb;
  v_record_digest char(64);
  v_queued_receipt_digest char(64);
  v_audit_id uuid;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF (p).request_id IS NULL OR (p).request_digest !~ '^[0-9a-f]{64}$'
     OR (p).donation_intent_id IS NULL OR (p).binding_id IS NULL
     OR (p).claim_digest !~ '^[0-9a-f]{64}$'
     OR (p).provider NOT IN ('TOSS_PAYMENTS','KAKAO_PAY','STRIPE')
     OR (p).provider_issue_idempotency_key_hmac !~ '^[0-9a-f]{64}$'
     OR NOT ops.secret_reference_is_version_pinned(
       (p).billing_key_secret_reference
     )
     OR (p).billing_key_secret_reference IS DISTINCT FROM
       'fixture://billing-key/'||(p).binding_id::text||'@v2'
     OR (p).billing_key_hmac !~ '^[0-9a-f]{64}$'
     OR (p).billing_key_hmac_key_version !~ '^sha256:[0-9a-f]{16}$'
     OR (p).credential_use_policy NOT IN ('SINGLE_CHARGE','RECURRING')
     OR (p).provider_request_digest !~ '^[0-9a-f]{64}$'
     OR (p).provider_response_digest !~ '^[0-9a-f]{64}$'
     OR (p).provider_http_status NOT BETWEEN 200 AND 299
     OR (p).completion_request_digest IS DISTINCT FROM
       ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
         'schemaVersion','r6e-payment-binding-completion.v1',
         'requestId',(p).request_id,
         'requestDigest',btrim((p).request_digest),
         'donationIntentId',(p).donation_intent_id,
         'bindingId',(p).binding_id,'claimDigest',btrim((p).claim_digest),
         'provider',(p).provider,
         'providerIssueIdempotencyKeyHmac',
           btrim((p).provider_issue_idempotency_key_hmac),
         'billingKeySecretReference',(p).billing_key_secret_reference,
         'billingKeyHmac',btrim((p).billing_key_hmac),
         'billingKeyHmacKeyVersion',(p).billing_key_hmac_key_version,
         'credentialUsePolicy',(p).credential_use_policy,
         'providerRequestDigest',btrim((p).provider_request_digest),
         'providerResponseDigest',btrim((p).provider_response_digest),
         'providerHttpStatus',(p).provider_http_status
       )) THEN
    RAISE EXCEPTION 'R6E_PAYMENT_BINDING_COMPLETION_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_head
  FROM ops.payment_method_bindings
  WHERE root_binding_id=(p).binding_id
  ORDER BY revision DESC
  LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_BINDING_NOT_FOUND'
      USING ERRCODE='P0002';
  END IF;
  IF v_head.request_id IS DISTINCT FROM (p).request_id
     OR v_head.request_digest IS DISTINCT FROM (p).request_digest
     OR v_head.donation_intent_id IS DISTINCT FROM (p).donation_intent_id
     OR v_head.claim_digest IS DISTINCT FROM (p).claim_digest
     OR v_head.provider IS DISTINCT FROM (p).provider
     OR v_head.provider_issue_idempotency_key_hmac
       IS DISTINCT FROM (p).provider_issue_idempotency_key_hmac
     OR v_head.credential_use_policy
       IS DISTINCT FROM (p).credential_use_policy THEN
    RETURN (
      'CONFLICT',(p).request_id,v_head.donation_intent_id,
      v_head.root_binding_id,NULL,NULL,v_head.reserved_job_id,
      v_head.binding_state,v_head.queued_receipt_digest,NULL
    )::ops.r6e_payment_method_binding_receipt_v1;
  END IF;
  IF v_head.binding_state='ACTIVE' THEN
    RETURN (
      CASE WHEN v_head.completion_request_digest=(p).completion_request_digest
        AND v_head.billing_key_secret_reference=
          (p).billing_key_secret_reference
        AND v_head.billing_key_hmac=(p).billing_key_hmac
        AND v_head.provider_issue_request_digest=(p).provider_request_digest
        AND v_head.provider_issue_response_digest=(p).provider_response_digest
        THEN 'REPLAY' ELSE 'CONFLICT' END,
      (p).request_id,v_head.donation_intent_id,v_head.root_binding_id,
      v_head.id,v_head.record_digest,v_head.queued_job_id,'QUEUED',
      v_head.queued_receipt_digest,NULL
    )::ops.r6e_payment_method_binding_receipt_v1;
  END IF;
  IF v_head.binding_state<>'PENDING_PROVIDER' THEN
    RETURN (
      'CONFLICT',(p).request_id,v_head.donation_intent_id,
      v_head.root_binding_id,NULL,NULL,v_head.reserved_job_id,
      v_head.binding_state,v_head.queued_receipt_digest,NULL
    )::ops.r6e_payment_method_binding_receipt_v1;
  END IF;
  v_record_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'billingKeyHmac',btrim((p).billing_key_hmac),
    'billingKeyHmacKeyVersion',(p).billing_key_hmac_key_version,
    'billingKeySecretReference',(p).billing_key_secret_reference,
    'bindingEffect','ACTIVATION','bindingId',v_active_id,
    'bindingState','ACTIVE','claimDigest',btrim(v_head.claim_digest),
    'completionRequestDigest',btrim((p).completion_request_digest),
    'providerIssueRequestDigest',btrim((p).provider_request_digest),
    'providerIssueResponseDigest',btrim((p).provider_response_digest),
    'revision',v_head.revision+1,'rootBindingId',v_head.root_binding_id
  ));
  v_scheduled_for:=to_char(
    v_head.first_charge_at AT TIME ZONE 'UTC',
    'YYYY-MM-DD"T"HH24:MI:SS"Z"'
  );
  v_charge_idempotency_digest:=encode(extensions.digest(
    convert_to('gurine-donation-charge-job-idempotency.v1','UTF8')
      ||decode('00','hex')||uuid_send(v_logical_charge_id)
      ||convert_to(btrim(v_record_digest),'UTF8')
      ||convert_to(v_scheduled_for,'UTF8'),
    'sha256'
  ),'hex')::char(64);
  v_payload:=jsonb_build_object(
    'schemaVersion','donation-charge-job.v1',
    'donationScheduleId',v_head.schedule_id,
    'donationScheduleVersion',v_head.schedule_version,
    'donationScheduleDigest',btrim(v_head.schedule_digest),
    'paymentMethodBindingId',v_active_id,
    'paymentMethodBindingDigest',btrim(v_record_digest),
    'offerVersionId',v_head.offer_version_id,
    'offerDigest',btrim(v_head.offer_digest),
    'tierId',v_head.tier_id,
    'consentReceiptDigest',btrim(v_head.consent_receipt_digest),
    'logicalChargeId',v_logical_charge_id,
    'chargeIdempotencyKeySha256',btrim(v_charge_idempotency_digest),
    'scheduledFor',v_scheduled_for
  );
  v_queued_receipt_digest:=ops.r6e_payment_sha256_jsonb_v1(
    jsonb_build_object(
      'jobId',v_head.reserved_job_id,'requestId',v_head.request_id,
      'schemaVersion','donation-intent-queued.v1','status','QUEUED',
      'paymentMethodBindingDigest',btrim(v_record_digest)
    )
  );
  v_audit_id:=ops.append_audit_event(
    'payment-binding:'||v_head.root_binding_id::text,'SERVICE',current_user,
    NULL,'R6E_PAYMENT_METHOD_BOUND','PaymentMethodBinding',
    v_head.root_binding_id::text,'payments.fixture','SUCCESS',
    'billing key reference bound and first charge queued',v_head.request_id,
    jsonb_build_object(
      'activeBindingDigest',btrim(v_record_digest),
      'completionRequestDigest',btrim((p).completion_request_digest),
      'jobBindingDigest',btrim(ops.r6e_payment_sha256_jsonb_v1(v_payload)),
      'queuedReceiptDigest',btrim(v_queued_receipt_digest)
    )
  );
  INSERT INTO ops.payment_method_bindings(
    id,root_binding_id,revision,binding_effect,supersedes_binding_id,
    predecessor_record_digest,donation_intent_id,request_id,request_digest,
    deployment_id,environment,fixture_authority,provider,
    merchant_account_hmac,merchant_hmac_key_version,donor_hmac,
    donor_group_hmac,donor_hmac_key_version,
    provider_issue_idempotency_key_hmac,
    provider_issue_idempotency_hmac_key_version,reserved_job_id,
    billing_key_secret_reference,billing_key_hmac,billing_key_hmac_key_version,
    credential_use_policy,schedule_kind,schedule_id,schedule_version,
    schedule_digest,offer_version_id,offer_digest,tier_id,first_charge_at,
    mandate_amount,currency,consent_receipt_digest,mandate_digest,
    binding_state,claim_digest,provider_issue_request_digest,
    provider_issue_response_digest,provider_issue_http_status,
    completion_request_digest,queued_job_id,queued_receipt_digest,failure_code,
    failure_evidence_digest,claimed_at,bound_at,revoked_at,terminal_at,
    audit_event_id,record_digest,recorded_at
  ) VALUES (
    v_active_id,v_head.root_binding_id,v_head.revision+1,'ACTIVATION',
    v_head.id,v_head.record_digest,v_head.donation_intent_id,v_head.request_id,
    v_head.request_digest,v_head.deployment_id,v_head.environment,
    v_head.fixture_authority,v_head.provider,v_head.merchant_account_hmac,
    v_head.merchant_hmac_key_version,v_head.donor_hmac,
    v_head.donor_group_hmac,v_head.donor_hmac_key_version,
    v_head.provider_issue_idempotency_key_hmac,
    v_head.provider_issue_idempotency_hmac_key_version,v_head.reserved_job_id,
    (p).billing_key_secret_reference,(p).billing_key_hmac,
    (p).billing_key_hmac_key_version,v_head.credential_use_policy,
    v_head.schedule_kind,v_head.schedule_id,v_head.schedule_version,
    v_head.schedule_digest,v_head.offer_version_id,v_head.offer_digest,
    v_head.tier_id,v_head.first_charge_at,v_head.mandate_amount,v_head.currency,
    v_head.consent_receipt_digest,v_head.mandate_digest,'ACTIVE',
    v_head.claim_digest,(p).provider_request_digest,
    (p).provider_response_digest,(p).provider_http_status,
    (p).completion_request_digest,v_head.reserved_job_id,
    v_queued_receipt_digest,NULL,NULL,v_head.claimed_at,v_now,NULL,v_now,
    v_audit_id,v_record_digest,v_now
  );
  INSERT INTO ops.jobs(
    id,job_type,queue,status,priority,payload,dedupe_key,run_after,
    max_attempts,created_at,updated_at
  ) VALUES (
    v_head.reserved_job_id,'DONATION_CHARGE','billing-gateway','QUEUED',50,
    v_payload,
    'donation-charge:'||v_head.schedule_id::text||':'
      ||v_head.schedule_version::text||':'||v_scheduled_for,
    v_head.first_charge_at,8,v_now,v_now
  );
  RETURN (
    'APPLIED',(p).request_id,v_head.donation_intent_id,
    v_head.root_binding_id,v_active_id,v_record_digest,v_head.reserved_job_id,
    'QUEUED',v_queued_receipt_digest,v_audit_id
  )::ops.r6e_payment_method_binding_receipt_v1;
END
$$;

CREATE FUNCTION ops.fail_r6e_donation_intent_v1(
  p ops.r6e_donation_intent_fail_v1
) RETURNS ops.r6e_payment_transition_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_head ops.payment_method_bindings%ROWTYPE;
  v_id uuid:=gen_random_uuid();
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_digest char(64);
  v_audit_id uuid;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF (p).request_id IS NULL OR (p).request_digest !~ '^[0-9a-f]{64}$'
     OR (p).donation_intent_id IS NULL OR (p).binding_id IS NULL
     OR (p).claim_digest !~ '^[0-9a-f]{64}$'
     OR (p).safe_code !~ '^[A-Z0-9_]{1,100}$'
     OR (p).failure_evidence_digest IS DISTINCT FROM
       ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
         'schemaVersion','r6e-donation-intent-failure.v1',
         'requestId',(p).request_id,
         'requestDigest',btrim((p).request_digest),
         'donationIntentId',(p).donation_intent_id,
         'bindingId',(p).binding_id,
         'claimDigest',btrim((p).claim_digest),'safeCode',(p).safe_code
       )) THEN
    RAISE EXCEPTION 'R6E_DONATION_INTENT_FAILURE_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_head
  FROM ops.payment_method_bindings
  WHERE root_binding_id=(p).binding_id
  ORDER BY revision DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_BINDING_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  IF v_head.request_id IS DISTINCT FROM (p).request_id
     OR v_head.request_digest IS DISTINCT FROM (p).request_digest
     OR v_head.donation_intent_id IS DISTINCT FROM (p).donation_intent_id
     OR v_head.claim_digest IS DISTINCT FROM (p).claim_digest THEN
    RETURN (
      'CONFLICT',v_head.root_binding_id,v_head.id,v_head.binding_state,
      v_head.record_digest,NULL
    )::ops.r6e_payment_transition_receipt_v1;
  END IF;
  IF v_head.binding_state='FAILED' THEN
    RETURN (
      CASE WHEN v_head.failure_code=(p).safe_code
        AND v_head.failure_evidence_digest=(p).failure_evidence_digest
        THEN 'REPLAY' ELSE 'CONFLICT' END,
      v_head.root_binding_id,v_head.id,v_head.binding_state,
      v_head.record_digest,NULL
    )::ops.r6e_payment_transition_receipt_v1;
  END IF;
  IF v_head.binding_state<>'PENDING_PROVIDER' THEN
    RETURN (
      'CONFLICT',v_head.root_binding_id,v_head.id,v_head.binding_state,
      v_head.record_digest,NULL
    )::ops.r6e_payment_transition_receipt_v1;
  END IF;
  v_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'bindingEffect','FAILURE','bindingId',v_id,'bindingState','FAILED',
    'failureCode',(p).safe_code,'failureEvidenceDigest',
      btrim((p).failure_evidence_digest),
    'predecessorRecordDigest',btrim(v_head.record_digest),
    'revision',v_head.revision+1,'rootBindingId',v_head.root_binding_id
  ));
  v_audit_id:=ops.append_audit_event(
    'payment-binding:'||v_head.root_binding_id::text,'SERVICE',current_user,
    NULL,'R6E_DONATION_INTENT_FAILED','PaymentMethodBinding',
    v_head.root_binding_id::text,'payments.fixture','FAILURE',(p).safe_code,
    v_head.request_id,jsonb_build_object(
      'failureEvidenceDigest',btrim((p).failure_evidence_digest),
      'recordDigest',btrim(v_digest)
    )
  );
  INSERT INTO ops.payment_method_bindings(
    id,root_binding_id,revision,binding_effect,supersedes_binding_id,
    predecessor_record_digest,donation_intent_id,request_id,request_digest,
    deployment_id,environment,fixture_authority,provider,
    merchant_account_hmac,merchant_hmac_key_version,donor_hmac,
    donor_group_hmac,donor_hmac_key_version,
    provider_issue_idempotency_key_hmac,
    provider_issue_idempotency_hmac_key_version,reserved_job_id,
    billing_key_secret_reference,billing_key_hmac,billing_key_hmac_key_version,
    credential_use_policy,schedule_kind,schedule_id,schedule_version,
    schedule_digest,offer_version_id,offer_digest,tier_id,first_charge_at,
    mandate_amount,currency,consent_receipt_digest,mandate_digest,
    binding_state,claim_digest,provider_issue_request_digest,
    provider_issue_response_digest,provider_issue_http_status,
    completion_request_digest,queued_job_id,queued_receipt_digest,failure_code,
    failure_evidence_digest,claimed_at,bound_at,revoked_at,terminal_at,
    audit_event_id,record_digest,recorded_at
  ) VALUES (
    v_id,v_head.root_binding_id,v_head.revision+1,'FAILURE',v_head.id,
    v_head.record_digest,v_head.donation_intent_id,v_head.request_id,
    v_head.request_digest,v_head.deployment_id,v_head.environment,
    v_head.fixture_authority,v_head.provider,v_head.merchant_account_hmac,
    v_head.merchant_hmac_key_version,v_head.donor_hmac,
    v_head.donor_group_hmac,v_head.donor_hmac_key_version,
    v_head.provider_issue_idempotency_key_hmac,
    v_head.provider_issue_idempotency_hmac_key_version,v_head.reserved_job_id,
    NULL,NULL,NULL,v_head.credential_use_policy,v_head.schedule_kind,
    v_head.schedule_id,v_head.schedule_version,v_head.schedule_digest,
    v_head.offer_version_id,v_head.offer_digest,v_head.tier_id,
    v_head.first_charge_at,v_head.mandate_amount,v_head.currency,
    v_head.consent_receipt_digest,v_head.mandate_digest,'FAILED',
    v_head.claim_digest,NULL,NULL,NULL,NULL,NULL,NULL,(p).safe_code,
    (p).failure_evidence_digest,v_head.claimed_at,NULL,NULL,v_now,
    v_audit_id,v_digest,v_now
  );
  RETURN (
    'APPLIED',v_head.root_binding_id,v_id,'FAILED',v_digest,v_audit_id
  )::ops.r6e_payment_transition_receipt_v1;
END
$$;

CREATE FUNCTION ops.apply_r6e_payment_observation_v1(
  p_attempt_id uuid,
  p_observation ops.r6e_payment_observation_v1,
  p_completion_request_digest char(64)
) RETURNS ops.r6e_donation_charge_terminal_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
SET timezone='UTC'
AS $$
DECLARE
  v_head ops.payment_charge_attempts%ROWTYPE;
  v_fact ops.donation_facts%ROWTYPE;
  v_prior_fact ops.donation_facts%ROWTYPE;
  v_binding ops.payment_method_bindings%ROWTYPE;
  v_job ops.jobs%ROWTYPE;
  v_task ops.tasks%ROWTYPE;
  v_id uuid:=gen_random_uuid();
  v_fact_id uuid;
  v_binding_revoke_id uuid;
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_producer_operation_id text:=COALESCE(
    NULLIF(current_setting('gurine.payment_producer_operation',true),''),
    'private.ExecuteDonationCharge'
  );
  v_effective_state text;
  v_terminal_at timestamptz;
  v_record_digest char(64);
  v_fact_digest char(64);
  v_binding_revoke_digest char(64);
  v_audit_id uuid;
  v_event_id uuid;
  v_review_event_id uuid;
  v_changed bigint;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_PAYMENT_OBSERVATION_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF v_producer_operation_id NOT IN (
       'private.ExecuteDonationCharge','private.ReceivePaymentWebhook'
     ) THEN
    RAISE EXCEPTION 'R6E_PAYMENT_OBSERVATION_PRODUCER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_attempt_id IS NULL
     OR (p_observation).attempt_id IS DISTINCT FROM p_attempt_id
     OR (p_observation).provider NOT IN (
       'TOSS_PAYMENTS','KAKAO_PAY','STRIPE'
     )
     OR (p_observation).provider_payment_id_digest !~ '^[0-9a-f]{64}$'
     OR (p_observation).merchant_order_id_digest !~ '^[0-9a-f]{64}$'
     OR (p_observation).amount_whole_krw IS NULL
     OR (p_observation).amount_whole_krw<1
     OR (p_observation).payment_state NOT IN (
       'SUCCEEDED','FAILED','CANCELED','PARTIALLY_REFUNDED','REFUNDED'
     )
     OR (p_observation).provider_observed_at IS NULL
     OR (p_observation).transport_request_digest !~ '^[0-9a-f]{64}$'
     OR (p_observation).transport_response_digest !~ '^[0-9a-f]{64}$'
     OR (p_observation).provider_fetch_digest !~ '^[0-9a-f]{64}$'
     OR (p_observation).fixture_authority<>'TEST_FIXTURE'
     OR (p_observation).test_payment_outcome_config_digest
       !~ '^[0-9a-f]{64}$'
     OR p_completion_request_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_PAYMENT_OBSERVATION_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_head FROM ops.payment_charge_attempts
  WHERE root_attempt_id=p_attempt_id
  ORDER BY observation_version DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_ATTEMPT_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  IF p_completion_request_digest IS DISTINCT FROM
       ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
         'schemaVersion','r6e-payment-observation-completion.v1',
         'attemptId',p_attempt_id,
         'claimDigest',btrim(v_head.request_digest),
         'producerOperationId',v_producer_operation_id,
         'provider',(p_observation).provider,
         'providerPaymentIdDigest',
           btrim((p_observation).provider_payment_id_digest),
         'merchantOrderIdDigest',
           btrim((p_observation).merchant_order_id_digest),
         'amountWholeKrw',(p_observation).amount_whole_krw,
         'paymentState',(p_observation).payment_state,
         'providerObservedAt',(p_observation).provider_observed_at,
         'transportRequestDigest',
           btrim((p_observation).transport_request_digest),
         'transportResponseDigest',
           btrim((p_observation).transport_response_digest),
         'providerFetchDigest',btrim((p_observation).provider_fetch_digest),
         'fixtureAuthority',(p_observation).fixture_authority,
         'testPaymentOutcomeConfigDigest',
           btrim((p_observation).test_payment_outcome_config_digest)
       )) THEN
    RAISE EXCEPTION 'R6E_PAYMENT_OBSERVATION_REQUEST_DIGEST_INVALID'
      USING ERRCODE='22023';
  END IF;
  v_effective_state:=CASE (p_observation).payment_state
    WHEN 'CANCELED' THEN 'FAILED'
    WHEN 'PARTIALLY_REFUNDED' THEN 'RECONCILIATION_REQUIRED'
    ELSE (p_observation).payment_state END;
  IF v_head.provider IS DISTINCT FROM (p_observation).provider
     OR v_head.expected_provider_payment_id_digest
       IS DISTINCT FROM (p_observation).provider_payment_id_digest
     OR v_head.merchant_order_id_digest
       IS DISTINCT FROM (p_observation).merchant_order_id_digest
     OR v_head.amount IS DISTINCT FROM
       (p_observation).amount_whole_krw::numeric THEN
    RETURN (
      'CONFLICT',v_head.root_attempt_id,v_head.attempt_state,
      v_head.terminal_authority,v_head.producer_operation_id,
      v_head.record_digest,v_head.fixture_authority,
      v_head.test_payment_outcome_config_digest,'NONE',
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,v_head.audit_event_id
    )::ops.r6e_donation_charge_terminal_receipt_v1;
  END IF;
  -- The active communication contract has no exact PAYMENT_REVIEW topic,
  -- endpoint-selection rule, or deployment authority.  A provider-confirmed
  -- failure therefore cannot be upgraded into a task or notification.  Stop
  -- after validation and authoritative reads, before the first ledger, task,
  -- audit, outbox, communication-intent, donation, or job mutation.
  IF (p_observation).payment_state IN ('FAILED','CANCELED') THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_AUTHORIZATION_NOT_CURRENT'
      USING ERRCODE='55000';
  END IF;
  IF (p_observation).payment_state='PARTIALLY_REFUNDED' THEN
    IF v_head.attempt_state='RECONCILIATION_REQUIRED'
       AND v_head.reconciliation_reason='PARTIAL_REFUND_AMOUNT_UNAVAILABLE' THEN
      RETURN (
        CASE WHEN v_head.provider_fetch_digest=
            (p_observation).provider_fetch_digest
          AND v_head.completion_request_digest=p_completion_request_digest
          THEN 'REPLAY' ELSE 'CONFLICT' END,
        v_head.root_attempt_id,v_head.attempt_state,NULL,
        v_head.producer_operation_id,v_head.record_digest,
        v_head.fixture_authority,v_head.test_payment_outcome_config_digest,
        'NONE',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
        NULL,NULL,NULL,NULL,NULL,NULL,v_head.audit_event_id
      )::ops.r6e_donation_charge_terminal_receipt_v1;
    END IF;
    IF v_head.attempt_state NOT IN (
         'REQUESTED','PROVIDER_ACCEPTED','SUCCEEDED','RECONCILIATION_REQUIRED'
       ) THEN
      RETURN (
        'CONFLICT',v_head.root_attempt_id,v_head.attempt_state,
        v_head.terminal_authority,v_head.producer_operation_id,
        v_head.record_digest,v_head.fixture_authority,
        v_head.test_payment_outcome_config_digest,'NONE',
        NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
        NULL,NULL,NULL,NULL,v_head.audit_event_id
      )::ops.r6e_donation_charge_terminal_receipt_v1;
    END IF;
    v_record_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
      'schemaVersion','r6e-payment-charge-attempt.v1',
      'attemptState','RECONCILIATION_REQUIRED',
      'completionRequestDigest',btrim(p_completion_request_digest),
      'evidenceDigest',btrim((p_observation).provider_fetch_digest),
      'observationId',v_id,
      'observationVersion',v_head.observation_version+1,
      'predecessorRecordDigest',btrim(v_head.record_digest),
      'producerOperationId',v_producer_operation_id,
      'providerObservedState','PARTIALLY_REFUNDED',
      'reason','PARTIAL_REFUND_AMOUNT_UNAVAILABLE',
      'rootAttemptId',v_head.root_attempt_id
    ));
    v_audit_id:=ops.append_audit_event(
      'payment-attempt:'||v_head.root_attempt_id::text,'SERVICE',current_user,
      NULL,'R6E_PARTIAL_REFUND_RECONCILIATION_REQUIRED',
      'PaymentChargeAttempt',v_head.root_attempt_id::text,
      'payments.reconcile','FAILURE','PARTIAL_REFUND_AMOUNT_UNAVAILABLE',
      gen_random_uuid(),jsonb_build_object(
        'providerFetchDigest',btrim((p_observation).provider_fetch_digest),
        'recordDigest',btrim(v_record_digest),'donationMutationCount',0,
        'fundingMutationCount',0,'reviewTaskMutationCount',0,
        'publicAccessMutationCount',0
      )
    );
    INSERT INTO ops.payment_charge_attempts(
      id,root_attempt_id,observation_version,observation_effect,
      supersedes_attempt_id,predecessor_record_digest,
      payment_method_binding_id,payment_method_binding_digest,job_id,worker_id,
      job_lease_token_digest,job_fencing_token,job_binding_digest,
      logical_charge_id,charge_idempotency_key_sha256,provider,
      provider_idempotency_key_hmac,provider_idempotency_hmac_key_version,
      merchant_order_id_hmac,merchant_order_hmac_key_version,
      merchant_order_id_digest,expected_provider_payment_id_digest,
      provider_locator_authority,provider_payment_id_digest,
      provider_observed_state,purpose,producer_operation_id,amount,currency,
      attempt_state,request_digest,provider_transport_request_digest,
      provider_transport_response_digest,provider_fetch_digest,
      fixture_authority,test_payment_outcome_config_digest,
      completion_request_digest,terminal_authority,local_failure_code,
      local_failure_evidence_digest,reconciliation_reason,
      reconciliation_evidence_digest,requested_at,provider_observed_at,
      terminal_at,audit_event_id,record_digest,recorded_at
    ) SELECT
      v_id,root_attempt_id,observation_version+1,'RECONCILIATION',id,
      record_digest,payment_method_binding_id,payment_method_binding_digest,
      job_id,worker_id,job_lease_token_digest,job_fencing_token,
      job_binding_digest,logical_charge_id,charge_idempotency_key_sha256,
      provider,provider_idempotency_key_hmac,
      provider_idempotency_hmac_key_version,merchant_order_id_hmac,
      merchant_order_hmac_key_version,merchant_order_id_digest,
      expected_provider_payment_id_digest,provider_locator_authority,
      (p_observation).provider_payment_id_digest,'PARTIALLY_REFUNDED',purpose,
      v_producer_operation_id,amount,currency,'RECONCILIATION_REQUIRED',
      request_digest,(p_observation).transport_request_digest,
      (p_observation).transport_response_digest,
      (p_observation).provider_fetch_digest,(p_observation).fixture_authority,
      (p_observation).test_payment_outcome_config_digest,
      p_completion_request_digest,NULL,NULL,NULL,
      'PARTIAL_REFUND_AMOUNT_UNAVAILABLE',
      (p_observation).provider_fetch_digest,requested_at,
      (p_observation).provider_observed_at,NULL,v_audit_id,v_record_digest,
      v_now
    FROM ops.payment_charge_attempts WHERE id=v_head.id;
    SELECT * INTO v_job FROM ops.jobs WHERE id=v_head.job_id FOR UPDATE;
    IF v_job.status='RUNNING' THEN
      UPDATE ops.job_attempts SET finished_at=v_now,outcome='FAILED',
        error_code='RECONCILIATION_REQUIRED',
        error_detail=btrim((p_observation).provider_fetch_digest),
        metrics=jsonb_build_object(
          'schemaVersion','r6e-donation-charge-job-terminal.v1',
          'attemptId',v_head.root_attempt_id,
          'attemptDigest',btrim(v_record_digest),
          'reconciliationReason','PARTIAL_REFUND_AMOUNT_UNAVAILABLE'
        )
      WHERE job_id=v_job.id AND attempt=v_job.attempt_count
        AND worker_id=v_job.lease_owner AND fencing_token=v_job.fencing_token
        AND finished_at IS NULL;
      GET DIAGNOSTICS v_changed=ROW_COUNT;
      IF v_changed<>1 THEN
        RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_ATTEMPT_STALE'
          USING ERRCODE='40001';
      END IF;
      UPDATE ops.jobs SET status='FAILED',completed_at=v_now,
        lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
        version=version+1,last_error_code='RECONCILIATION_REQUIRED',
        last_error_detail=btrim((p_observation).provider_fetch_digest),
        updated_at=v_now
      WHERE id=v_job.id AND status='RUNNING'
        AND lease_owner=v_job.lease_owner AND lease_token=v_job.lease_token
        AND fencing_token=v_job.fencing_token;
      GET DIAGNOSTICS v_changed=ROW_COUNT;
      IF v_changed<>1 THEN
        RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_STALE'
          USING ERRCODE='40001';
      END IF;
    END IF;
    RETURN (
      'RECONCILIATION_REQUIRED',v_head.root_attempt_id,
      'RECONCILIATION_REQUIRED',NULL,v_producer_operation_id,
      v_record_digest,(p_observation).fixture_authority,
      (p_observation).test_payment_outcome_config_digest,'NONE',
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
      NULL,NULL,NULL,NULL,v_audit_id
    )::ops.r6e_donation_charge_terminal_receipt_v1;
  END IF;
  IF v_head.attempt_state IN ('SUCCEEDED','FAILED','REFUNDED')
     AND NOT (
       v_head.attempt_state='SUCCEEDED'
       AND (p_observation).payment_state='REFUNDED'
     ) THEN
    SELECT * INTO v_fact FROM ops.donation_facts
    WHERE payment_charge_attempt_id=v_head.root_attempt_id
      AND payment_charge_attempt_digest=v_head.record_digest
    ORDER BY revision DESC LIMIT 1;
    SELECT * INTO v_task FROM ops.tasks
    WHERE task_type='PAYMENT_REVIEW'
      AND payment_review_source_kind='DONATION_PAYMENT_FAILURE'
      AND payment_review_source_receipt_id=v_head.root_attempt_id;
    IF v_fact.id IS NOT NULL THEN
      SELECT o.id INTO v_event_id FROM ops.outbox o
      WHERE o.aggregate_type='DonationFact'
        AND o.aggregate_id=v_fact.root_fact_id::text
        AND o.aggregate_version=v_fact.revision
        AND o.event_type='donation.fact_recorded.v1';
      IF v_event_id IS NULL THEN
        RAISE EXCEPTION 'R6E_DONATION_OUTBOX_BINDING_MISSING'
          USING ERRCODE='55000';
      END IF;
    END IF;
    IF v_task.id IS NOT NULL THEN
      SELECT o.id INTO v_review_event_id FROM ops.outbox o
      WHERE o.aggregate_type='payment_review_task'
        AND o.aggregate_id=v_task.id::text
        AND o.aggregate_version=v_task.version
        AND o.event_type='notification.payment_review_requested.v1';
      IF v_review_event_id IS NULL THEN
        RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_OUTBOX_BINDING_MISSING'
          USING ERRCODE='55000';
      END IF;
    END IF;
    RETURN (
      CASE WHEN v_head.completion_request_digest=p_completion_request_digest
        AND v_head.provider_payment_id_digest=
          (p_observation).provider_payment_id_digest
        AND v_head.provider_fetch_digest=(p_observation).provider_fetch_digest
        AND v_head.test_payment_outcome_config_digest=
          (p_observation).test_payment_outcome_config_digest
        THEN 'REPLAY' ELSE 'CONFLICT' END,
      v_head.root_attempt_id,v_head.attempt_state,v_head.terminal_authority,
      v_head.producer_operation_id,v_head.record_digest,
      v_head.fixture_authority,v_head.test_payment_outcome_config_digest,
      'NONE',v_fact.id,v_fact.root_fact_id,v_fact.revision,v_fact.fact_effect,
      v_fact.fact_digest,
      v_fact.payment_charge_attempt_digest,v_fact.provider_fetch_digest,
      v_fact.recognized_at,v_event_id,
      v_task.id,v_task.version,v_task.creation_digest,
      v_task.payment_review_source_kind,
      v_task.payment_review_source_receipt_id,
      v_task.payment_review_source_receipt_digest,v_task.created_at,
      v_task.payment_review_notification_intent_id,v_review_event_id,
      v_head.audit_event_id
    )::ops.r6e_donation_charge_terminal_receipt_v1;
  END IF;
  IF (p_observation).payment_state='REFUNDED' THEN
    SELECT prior.* INTO v_prior_fact FROM ops.donation_facts AS prior
    WHERE prior.payment_charge_attempt_id=v_head.root_attempt_id
      AND NOT EXISTS (
        SELECT 1 FROM ops.donation_facts successor
        WHERE successor.supersedes_fact_id=prior.id
      )
    ORDER BY prior.revision DESC LIMIT 1 FOR UPDATE OF prior;
    IF v_prior_fact.id IS NULL OR v_prior_fact.fact_effect='REVERSAL' THEN
      RETURN (
        'CONFLICT',v_head.root_attempt_id,v_head.attempt_state,
        v_head.terminal_authority,v_head.producer_operation_id,
        v_head.record_digest,v_head.fixture_authority,
        v_head.test_payment_outcome_config_digest,'NONE',
        NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
        NULL,NULL,NULL,NULL,v_head.audit_event_id
      )::ops.r6e_donation_charge_terminal_receipt_v1;
    END IF;
  ELSIF v_head.attempt_state NOT IN (
    'REQUESTED','PROVIDER_ACCEPTED','RECONCILIATION_REQUIRED'
  ) THEN
    RETURN (
      'CONFLICT',v_head.root_attempt_id,v_head.attempt_state,
      v_head.terminal_authority,v_head.producer_operation_id,
      v_head.record_digest,NULL,NULL,'NONE',
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
      NULL,NULL,NULL,NULL,v_head.audit_event_id
    )::ops.r6e_donation_charge_terminal_receipt_v1;
  END IF;
  v_terminal_at:=greatest(v_now,(p_observation).provider_observed_at);
  v_record_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-payment-charge-attempt.v1',
    'attemptState',v_effective_state,
    'completionRequestDigest',btrim(p_completion_request_digest),
    'fixtureAuthority',(p_observation).fixture_authority,
    'observationId',v_id,
    'observationVersion',v_head.observation_version+1,
    'predecessorRecordDigest',btrim(v_head.record_digest),
    'producerOperationId',v_producer_operation_id,
    'providerFetchDigest',btrim((p_observation).provider_fetch_digest),
    'providerPaymentIdDigest',
      btrim((p_observation).provider_payment_id_digest),
    'rootAttemptId',v_head.root_attempt_id,
    'providerObservedState',(p_observation).payment_state,
    'terminalAuthority','PROVIDER_FETCH_CONFIRMED',
    'testPaymentOutcomeConfigDigest',
      btrim((p_observation).test_payment_outcome_config_digest)
  ));
  v_audit_id:=ops.append_audit_event(
    'payment-attempt:'||v_head.root_attempt_id::text,'SERVICE',current_user,
    NULL,'R6E_DONATION_CHARGE_OBSERVED','PaymentChargeAttempt',
    v_head.root_attempt_id::text,'payments.fixture',
    CASE WHEN (p_observation).payment_state='SUCCEEDED'
      THEN 'SUCCESS'::ops.audit_outcome ELSE 'FAILURE'::ops.audit_outcome END,
    (p_observation).payment_state,gen_random_uuid(),jsonb_build_object(
      'fixtureAuthority',(p_observation).fixture_authority,
      'producerOperationId',v_producer_operation_id,
      'providerFetchDigest',btrim((p_observation).provider_fetch_digest),
      'recordDigest',btrim(v_record_digest),
      'testPaymentOutcomeConfigDigest',
        btrim((p_observation).test_payment_outcome_config_digest)
    )
  );
  INSERT INTO ops.payment_charge_attempts(
    id,root_attempt_id,observation_version,observation_effect,
    supersedes_attempt_id,predecessor_record_digest,
    payment_method_binding_id,payment_method_binding_digest,job_id,worker_id,
    job_lease_token_digest,job_fencing_token,job_binding_digest,
    logical_charge_id,charge_idempotency_key_sha256,provider,
    provider_idempotency_key_hmac,provider_idempotency_hmac_key_version,
    merchant_order_id_hmac,merchant_order_hmac_key_version,
    merchant_order_id_digest,expected_provider_payment_id_digest,
    provider_locator_authority,provider_payment_id_digest,
    provider_observed_state,purpose,producer_operation_id,amount,
    currency,attempt_state,request_digest,provider_transport_request_digest,
    provider_transport_response_digest,provider_fetch_digest,
    fixture_authority,test_payment_outcome_config_digest,
    completion_request_digest,terminal_authority,local_failure_code,
    local_failure_evidence_digest,reconciliation_reason,
    reconciliation_evidence_digest,requested_at,provider_observed_at,
    terminal_at,audit_event_id,record_digest,recorded_at
  ) SELECT
    v_id,root_attempt_id,observation_version+1,'OBSERVATION',id,record_digest,
    payment_method_binding_id,payment_method_binding_digest,job_id,worker_id,
    job_lease_token_digest,job_fencing_token,job_binding_digest,
    logical_charge_id,charge_idempotency_key_sha256,provider,
    provider_idempotency_key_hmac,provider_idempotency_hmac_key_version,
    merchant_order_id_hmac,merchant_order_hmac_key_version,
    merchant_order_id_digest,expected_provider_payment_id_digest,
    provider_locator_authority,(p_observation).provider_payment_id_digest,
    (p_observation).payment_state,purpose,v_producer_operation_id,
    amount,currency,v_effective_state,request_digest,
    (p_observation).transport_request_digest,
    (p_observation).transport_response_digest,
    (p_observation).provider_fetch_digest,(p_observation).fixture_authority,
    (p_observation).test_payment_outcome_config_digest,
    p_completion_request_digest,'PROVIDER_FETCH_CONFIRMED',NULL,NULL,
    NULL,NULL,requested_at,
    (p_observation).provider_observed_at,v_terminal_at,v_audit_id,
    v_record_digest,v_now
  FROM ops.payment_charge_attempts WHERE id=v_head.id;
  IF (p_observation).payment_state='SUCCEEDED' THEN
    v_fact_id:=gen_random_uuid();
    v_fact_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
      'amountWholeKrw',v_head.amount::bigint,
      'chargeAttemptDigest',btrim(v_record_digest),
      'chargeAttemptId',v_head.root_attempt_id,
      'donationFactId',v_fact_id,'factEffect','ORIGINAL','revision',1,
      'providerFetchDigest',btrim((p_observation).provider_fetch_digest),
      'publicAccessGranted',false,'investigationExemption',false
    ));
    INSERT INTO ops.donation_facts(
      id,root_fact_id,revision,fact_effect,supersedes_fact_id,
      predecessor_fact_digest,deployment_id,payment_charge_attempt_id,
      payment_charge_attempt_digest,donor_hmac,donor_hmac_key_version,
      donor_group_hmac,donor_group_hmac_key_version,amount,currency,
      amount_basis,funding_source_kind,investigation_exemption,
      access_entitlement_granted,provider_fetch_digest,recognized_at,
      audit_event_id,fact_digest,recorded_at
    ) SELECT
      v_fact_id,v_fact_id,1,'ORIGINAL',NULL,NULL,b.deployment_id,
      v_head.root_attempt_id,v_record_digest,b.donor_hmac,
      b.donor_hmac_key_version,b.donor_group_hmac,b.donor_hmac_key_version,
      v_head.amount,'KRW','RECOGNIZED','DONATION',false,false,
      (p_observation).provider_fetch_digest,v_terminal_at,v_audit_id,
      v_fact_digest,v_now
    FROM ops.payment_method_bindings b
    WHERE b.id=v_head.payment_method_binding_id
      AND b.record_digest=v_head.payment_method_binding_digest;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'R6E_DONATION_BINDING_NOT_FOUND'
        USING ERRCODE='P0002';
    END IF;
    v_event_id:=ops.enqueue_outbox(
      'DonationFact',v_fact_id::text,1,'donation.fact_recorded.v1',
      jsonb_build_object(
        'donationFactId',v_fact_id,
        'donationFactDigest',btrim(v_fact_digest),
        'chargeAttemptId',v_head.root_attempt_id,
        'chargeAttemptDigest',btrim(v_record_digest),
        'providerFetchDigest',btrim((p_observation).provider_fetch_digest),
        'occurredAt',v_terminal_at
      ),v_terminal_at
    );
    SELECT * INTO v_fact FROM ops.donation_facts WHERE id=v_fact_id;
    SELECT * INTO v_binding FROM ops.payment_method_bindings
    WHERE id=v_head.payment_method_binding_id
      AND record_digest=v_head.payment_method_binding_digest
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'R6E_DONATION_BINDING_NOT_FOUND'
        USING ERRCODE='P0002';
    END IF;
    IF v_binding.credential_use_policy='SINGLE_CHARGE'
       AND NOT EXISTS (
         SELECT 1 FROM ops.payment_method_bindings successor
         WHERE successor.supersedes_binding_id=v_binding.id
       ) THEN
      v_binding_revoke_id:=gen_random_uuid();
      v_binding_revoke_digest:=ops.r6e_payment_sha256_jsonb_v1(
        jsonb_build_object(
          'schemaVersion','r6e-payment-method-binding.v1',
          'bindingEffect','REVOCATION','bindingId',v_binding_revoke_id,
          'bindingState','REVOKED','consumedByAttemptId',
            v_head.root_attempt_id,
          'predecessorRecordDigest',btrim(v_binding.record_digest),
          'revision',v_binding.revision+1,
          'rootBindingId',v_binding.root_binding_id
        )
      );
      INSERT INTO ops.payment_method_bindings(
        id,root_binding_id,revision,binding_effect,supersedes_binding_id,
        predecessor_record_digest,donation_intent_id,request_id,
        request_digest,deployment_id,environment,fixture_authority,provider,
        merchant_account_hmac,merchant_hmac_key_version,donor_hmac,
        donor_group_hmac,donor_hmac_key_version,
        provider_issue_idempotency_key_hmac,
        provider_issue_idempotency_hmac_key_version,reserved_job_id,
        billing_key_secret_reference,billing_key_hmac,
        billing_key_hmac_key_version,credential_use_policy,schedule_kind,
        schedule_id,schedule_version,schedule_digest,offer_version_id,
        offer_digest,tier_id,first_charge_at,mandate_amount,currency,
        consent_receipt_digest,mandate_digest,binding_state,claim_digest,
        provider_issue_request_digest,provider_issue_response_digest,
        provider_issue_http_status,completion_request_digest,queued_job_id,
        queued_receipt_digest,failure_code,failure_evidence_digest,claimed_at,
        bound_at,revoked_at,terminal_at,audit_event_id,record_digest,recorded_at
      ) VALUES (
        v_binding_revoke_id,v_binding.root_binding_id,v_binding.revision+1,
        'REVOCATION',v_binding.id,v_binding.record_digest,
        v_binding.donation_intent_id,v_binding.request_id,
        v_binding.request_digest,v_binding.deployment_id,
        v_binding.environment,v_binding.fixture_authority,v_binding.provider,
        v_binding.merchant_account_hmac,v_binding.merchant_hmac_key_version,
        v_binding.donor_hmac,v_binding.donor_group_hmac,
        v_binding.donor_hmac_key_version,
        v_binding.provider_issue_idempotency_key_hmac,
        v_binding.provider_issue_idempotency_hmac_key_version,
        v_binding.reserved_job_id,v_binding.billing_key_secret_reference,
        v_binding.billing_key_hmac,v_binding.billing_key_hmac_key_version,
        v_binding.credential_use_policy,v_binding.schedule_kind,
        v_binding.schedule_id,v_binding.schedule_version,
        v_binding.schedule_digest,v_binding.offer_version_id,
        v_binding.offer_digest,v_binding.tier_id,v_binding.first_charge_at,
        v_binding.mandate_amount,v_binding.currency,
        v_binding.consent_receipt_digest,v_binding.mandate_digest,'REVOKED',
        v_binding.claim_digest,v_binding.provider_issue_request_digest,
        v_binding.provider_issue_response_digest,
        v_binding.provider_issue_http_status,
        v_binding.completion_request_digest,v_binding.queued_job_id,
        v_binding.queued_receipt_digest,NULL,NULL,v_binding.claimed_at,
        v_binding.bound_at,v_terminal_at,v_terminal_at,v_audit_id,
        v_binding_revoke_digest,v_now
      );
    END IF;
  ELSIF (p_observation).payment_state='REFUNDED' THEN
    v_fact_id:=gen_random_uuid();
    v_fact_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
      'schemaVersion','r6e-donation-fact.v1',
      'amountWholeKrw',v_prior_fact.amount::bigint,
      'chargeAttemptDigest',btrim(v_record_digest),
      'chargeAttemptId',v_head.root_attempt_id,
      'donationFactId',v_fact_id,'factEffect','REVERSAL',
      'predecessorFactDigest',btrim(v_prior_fact.fact_digest),
      'revision',v_prior_fact.revision+1,
      'rootFactId',v_prior_fact.root_fact_id,
      'providerFetchDigest',btrim((p_observation).provider_fetch_digest),
      'publicAccessGranted',false,'investigationExemption',false
    ));
    INSERT INTO ops.donation_facts(
      id,root_fact_id,revision,fact_effect,supersedes_fact_id,
      predecessor_fact_digest,deployment_id,payment_charge_attempt_id,
      payment_charge_attempt_digest,donor_hmac,donor_hmac_key_version,
      donor_group_hmac,donor_group_hmac_key_version,amount,currency,
      amount_basis,funding_source_kind,investigation_exemption,
      access_entitlement_granted,provider_fetch_digest,recognized_at,
      audit_event_id,fact_digest,recorded_at
    ) VALUES (
      v_fact_id,v_prior_fact.root_fact_id,v_prior_fact.revision+1,'REVERSAL',
      v_prior_fact.id,v_prior_fact.fact_digest,v_prior_fact.deployment_id,
      v_head.root_attempt_id,v_record_digest,v_prior_fact.donor_hmac,
      v_prior_fact.donor_hmac_key_version,v_prior_fact.donor_group_hmac,
      v_prior_fact.donor_group_hmac_key_version,v_prior_fact.amount,
      v_prior_fact.currency,v_prior_fact.amount_basis,'DONATION',false,false,
      (p_observation).provider_fetch_digest,v_terminal_at,v_audit_id,
      v_fact_digest,v_now
    );
    v_event_id:=ops.enqueue_outbox(
      'DonationFact',v_prior_fact.root_fact_id::text,
      v_prior_fact.revision+1,'donation.fact_recorded.v1',
      jsonb_build_object(
        'donationFactId',v_fact_id,
        'donationFactDigest',btrim(v_fact_digest),
        'chargeAttemptId',v_head.root_attempt_id,
        'chargeAttemptDigest',btrim(v_record_digest),
        'providerFetchDigest',btrim((p_observation).provider_fetch_digest),
        'occurredAt',v_terminal_at
      ),v_terminal_at
    );
    SELECT * INTO v_fact FROM ops.donation_facts WHERE id=v_fact_id;
  END IF;
  IF v_task.id IS NOT NULL THEN
    SELECT event.id INTO v_review_event_id FROM ops.outbox AS event
    WHERE event.aggregate_type='payment_review_task'
      AND event.aggregate_id=v_task.id::text
      AND event.aggregate_version=v_task.version
      AND event.event_type='notification.payment_review_requested.v1';
    IF v_review_event_id IS NULL THEN
      RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_OUTBOX_BINDING_MISSING'
        USING ERRCODE='55000';
    END IF;
  END IF;
  SELECT * INTO v_job FROM ops.jobs WHERE id=v_head.job_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  IF v_job.status='RUNNING' THEN
    UPDATE ops.job_attempts SET finished_at=v_now,outcome='SUCCEEDED',
      error_code=NULL,error_detail=NULL,metrics=jsonb_build_object(
        'schemaVersion','r6e-donation-charge-job-terminal.v1',
        'producerOperationId',v_producer_operation_id,
        'attemptId',v_head.root_attempt_id,
        'attemptDigest',btrim(v_record_digest),'paymentState',v_effective_state
      )
    WHERE job_id=v_job.id AND attempt=v_job.attempt_count
      AND worker_id=v_job.lease_owner AND fencing_token=v_job.fencing_token
      AND finished_at IS NULL;
    GET DIAGNOSTICS v_changed=ROW_COUNT;
    IF v_changed<>1 THEN
      RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_ATTEMPT_STALE'
        USING ERRCODE='40001';
    END IF;
    UPDATE ops.jobs SET status='SUCCEEDED',completed_at=v_now,
      lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
      version=version+1,last_error_code=NULL,last_error_detail=NULL,
      updated_at=v_now
    WHERE id=v_job.id AND status='RUNNING'
      AND lease_owner=v_job.lease_owner AND lease_token=v_job.lease_token
      AND fencing_token=v_job.fencing_token;
    GET DIAGNOSTICS v_changed=ROW_COUNT;
    IF v_changed<>1 THEN
      RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_STALE' USING ERRCODE='40001';
    END IF;
  ELSIF v_producer_operation_id='private.ExecuteDonationCharge' THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_TERMINAL_CONFLICT'
      USING ERRCODE='40001';
  END IF;
  RETURN (
    'APPLIED',v_head.root_attempt_id,v_effective_state,
    'PROVIDER_FETCH_CONFIRMED',v_producer_operation_id,v_record_digest,
    (p_observation).fixture_authority,
    (p_observation).test_payment_outcome_config_digest,'NONE',
    v_fact.id,v_fact.root_fact_id,v_fact.revision,v_fact.fact_effect,
    v_fact.fact_digest,v_fact.payment_charge_attempt_digest,
    v_fact.provider_fetch_digest,v_fact.recognized_at,v_event_id,
    v_task.id,v_task.version,v_task.creation_digest,
    v_task.payment_review_source_kind,v_task.payment_review_source_receipt_id,
    v_task.payment_review_source_receipt_digest,v_task.created_at,
    v_task.payment_review_notification_intent_id,v_review_event_id,v_audit_id
  )::ops.r6e_donation_charge_terminal_receipt_v1;
END
$$;

CREATE FUNCTION ops.complete_r6e_donation_charge_v1(
  p ops.r6e_donation_charge_complete_v1
) RETURNS ops.r6e_donation_charge_terminal_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_root ops.payment_charge_attempts%ROWTYPE;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF p IS NULL OR (p).attempt_id IS NULL
     OR (p).claim_digest !~ '^[0-9a-f]{64}$'
     OR (p).completion_request_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_COMPLETION_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_root FROM ops.payment_charge_attempts
  WHERE root_attempt_id=(p).attempt_id AND observation_version=1
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_ATTEMPT_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  IF v_root.request_digest IS DISTINCT FROM (p).claim_digest THEN
    RETURN (
      'CONFLICT',v_root.root_attempt_id,v_root.attempt_state,
      v_root.terminal_authority,v_root.producer_operation_id,
      v_root.record_digest,v_root.fixture_authority,
      v_root.test_payment_outcome_config_digest,'NONE',
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,v_root.audit_event_id
    )::ops.r6e_donation_charge_terminal_receipt_v1;
  END IF;
  PERFORM set_config(
    'gurine.payment_producer_operation','private.ExecuteDonationCharge',true
  );
  RETURN ops.apply_r6e_payment_observation_v1(
    (p).attempt_id,(p).observation,(p).completion_request_digest
  );
END
$$;

CREATE FUNCTION ops.claim_r6e_provider_webhook_v1(
  p ops.r6e_provider_webhook_claim_v1
) RETURNS ops.r6e_provider_webhook_claim_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_existing ops.provider_webhook_receipts%ROWTYPE;
  v_charge ops.payment_charge_attempts%ROWTYPE;
  v_id uuid:=gen_random_uuid();
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_effect text:='ORIGINAL';
  v_revision bigint:=1;
  v_root_id uuid;
  v_digest char(64);
  v_audit_id uuid;
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_billing_gateway'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF (p).provider NOT IN ('TOSS_PAYMENTS','KAKAO_PAY','STRIPE')
     OR (p).event_identity_digest !~ '^[0-9a-f]{64}$'
     OR (p).locator_kind NOT IN (
       'PROVIDER_PAYMENT_ID','MERCHANT_ORDER_ID'
     ) OR (p).locator_digest !~ '^[0-9a-f]{64}$'
     OR (p).body_digest !~ '^[0-9a-f]{64}$'
     OR (p).hint_digest !~ '^[0-9a-f]{64}$'
     OR (p).authentication_state NOT IN (
       'VERIFIED','NOT_AVAILABLE_FETCH_REQUIRED'
     ) OR ((p).authentication_state='VERIFIED' AND (
       (p).signature_digest !~ '^[0-9a-f]{64}$'
       OR (p).signed_payload_digest !~ '^[0-9a-f]{64}$'
     )) OR ((p).authentication_state='NOT_AVAILABLE_FETCH_REQUIRED' AND (
       (p).signature_digest IS NOT NULL
       OR (p).signed_payload_digest IS NOT NULL
     )) OR ((p).provider='STRIPE'
       AND (p).authentication_state<>'VERIFIED')
     OR ((p).provider IN ('TOSS_PAYMENTS','KAKAO_PAY')
       AND (p).authentication_state<>'NOT_AVAILABLE_FETCH_REQUIRED')
     OR (p).claim_request_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_CLAIM_INVALID'
      USING ERRCODE='22023';
  END IF;
  -- The first row has no tuple to lock.  Serialize the immutable provider /
  -- event identity before both the absence read and audit/ledger append so a
  -- concurrent exact claim observes this transaction's committed receipt
  -- instead of racing the partial unique index.
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'r6e-provider-webhook-claim.v1:'||(p).provider||':'
      ||btrim((p).event_identity_digest),13
  ));
  SELECT * INTO v_existing FROM ops.provider_webhook_receipts
  WHERE provider=(p).provider
    AND provider_event_identity_digest=(p).event_identity_digest
  ORDER BY revision DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    IF v_existing.claim_request_digest IS DISTINCT FROM
         (p).claim_request_digest
       OR v_existing.locator_kind IS DISTINCT FROM (p).locator_kind
       OR v_existing.locator_digest IS DISTINCT FROM (p).locator_digest
       OR v_existing.body_digest IS DISTINCT FROM (p).body_digest
       OR v_existing.hint_digest IS DISTINCT FROM (p).hint_digest
       OR v_existing.authentication_state IS DISTINCT FROM
         (p).authentication_state
       OR v_existing.signature_digest IS DISTINCT FROM (p).signature_digest
       OR v_existing.signed_payload_digest IS DISTINCT FROM
         (p).signed_payload_digest THEN
      RETURN (
        'CONFLICT',(p).provider,(p).event_identity_digest,
        v_existing.root_receipt_id,v_existing.receipt_digest,
        v_existing.charge_attempt_id,v_existing.charge_attempt_digest,
        v_existing.logical_charge_id,v_existing.job_binding_digest,
        v_existing.charge_idempotency_key_sha256,
        v_existing.merchant_order_id_digest,v_existing.amount::bigint,
        v_existing.receipt_digest,NULL
      )::ops.r6e_provider_webhook_claim_receipt_v1;
    END IF;
    IF v_existing.claim_state='FETCH_CONFIRMED' THEN
      RETURN (
        'REPLAY',(p).provider,(p).event_identity_digest,
        v_existing.root_receipt_id,v_existing.receipt_digest,
        v_existing.charge_attempt_id,v_existing.charge_attempt_digest,
        v_existing.logical_charge_id,v_existing.job_binding_digest,
        v_existing.charge_idempotency_key_sha256,
        v_existing.merchant_order_id_digest,v_existing.amount::bigint,
        v_existing.receipt_digest,NULL
      )::ops.r6e_provider_webhook_claim_receipt_v1;
    ELSIF v_existing.claim_state='CLAIMED' THEN
      RETURN (
        'IN_PROGRESS',(p).provider,(p).event_identity_digest,
        v_existing.id,v_existing.receipt_digest,
        v_existing.charge_attempt_id,v_existing.charge_attempt_digest,
        v_existing.logical_charge_id,v_existing.job_binding_digest,
        v_existing.charge_idempotency_key_sha256,
        v_existing.merchant_order_id_digest,v_existing.amount::bigint,
        v_existing.receipt_digest,NULL
      )::ops.r6e_provider_webhook_claim_receipt_v1;
    END IF;
    v_root_id:=v_existing.root_receipt_id;
    v_revision:=v_existing.revision+1;
    v_effect:='RECLAIM';
    SELECT * INTO v_charge FROM ops.payment_charge_attempts
    WHERE root_attempt_id=v_existing.charge_attempt_id
    ORDER BY observation_version DESC LIMIT 1 FOR SHARE;
  ELSE
    SELECT head.* INTO v_charge
    FROM ops.payment_charge_attempts root
    JOIN LATERAL (
      SELECT current_row.* FROM ops.payment_charge_attempts current_row
      WHERE current_row.root_attempt_id=root.root_attempt_id
      ORDER BY current_row.observation_version DESC LIMIT 1
    ) head ON true
    WHERE root.observation_version=1 AND root.provider=(p).provider
      AND CASE (p).locator_kind
        WHEN 'PROVIDER_PAYMENT_ID' THEN
          root.expected_provider_payment_id_digest=(p).locator_digest
        ELSE root.merchant_order_id_digest=(p).locator_digest
      END
    FOR SHARE OF root;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_PAYMENT_NOT_FOUND'
        USING ERRCODE='P0002';
    END IF;
    v_root_id:=v_id;
  END IF;
  IF v_charge.root_attempt_id IS NULL
     OR v_charge.expected_provider_payment_id_digest IS NULL THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_PAYMENT_BINDING_INVALID'
      USING ERRCODE='55000';
  END IF;
  v_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'authenticationState',(p).authentication_state,
    'bodyDigest',btrim((p).body_digest),
    'chargeAttemptDigest',btrim(v_charge.record_digest),
    'chargeAttemptId',v_charge.root_attempt_id,
    'claimRequestDigest',btrim((p).claim_request_digest),
    'eventIdentityDigest',btrim((p).event_identity_digest),
    'hintDigest',btrim((p).hint_digest),'locatorDigest',
      btrim((p).locator_digest),'locatorKind',(p).locator_kind,
    'provider',(p).provider,'receiptEffect',v_effect,
    'revision',v_revision,'rootReceiptId',v_root_id
  ));
  v_audit_id:=ops.append_audit_event(
    'provider-webhook:'||(p).provider||':'
      ||btrim((p).event_identity_digest),'SERVICE',current_user,NULL,
    'R6E_PROVIDER_WEBHOOK_CLAIMED','ProviderWebhookReceipt',v_root_id::text,
    'payments.webhook','SUCCESS','webhook hint claimed',gen_random_uuid(),
    jsonb_build_object(
      'authenticationState',(p).authentication_state,
      'bodyDigest',btrim((p).body_digest),
      'eventIdentityDigest',btrim((p).event_identity_digest),
      'receiptDigest',btrim(v_digest)
    )
  );
  INSERT INTO ops.provider_webhook_receipts(
    id,root_receipt_id,revision,receipt_effect,supersedes_receipt_id,
    predecessor_receipt_digest,environment,fixture_authority,provider,
    provider_event_identity_digest,locator_kind,locator_digest,body_digest,
    hint_digest,authentication_state,signature_digest,signed_payload_digest,
    claim_state,claim_request_digest,charge_attempt_id,charge_attempt_digest,
    logical_charge_id,job_binding_digest,charge_idempotency_key_sha256,
    merchant_order_id_digest,amount,currency,release_code,
    release_evidence_digest,provider_payment_state,provider_payment_id_digest,
    provider_fetch_request_digest,provider_fetch_response_digest,
    provider_fetch_digest,payment_fixture_authority,
    test_payment_outcome_config_digest,completion_request_digest,
    provider_observed_at,resulting_charge_attempt_id,
    resulting_charge_attempt_digest,resulting_donation_fact_id,
    resulting_donation_fact_digest,claimed_at,released_at,fetched_at,
    audit_event_id,receipt_digest,recorded_at
  ) VALUES (
    v_id,v_root_id,v_revision,v_effect,
    CASE WHEN v_effect='RECLAIM' THEN v_existing.id ELSE NULL END,
    CASE WHEN v_effect='RECLAIM' THEN v_existing.receipt_digest ELSE NULL END,
    'TEST','TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY',(p).provider,
    (p).event_identity_digest,(p).locator_kind,(p).locator_digest,
    (p).body_digest,(p).hint_digest,(p).authentication_state,
    (p).signature_digest,(p).signed_payload_digest,'CLAIMED',
    (p).claim_request_digest,v_charge.root_attempt_id,v_charge.record_digest,
    v_charge.logical_charge_id,v_charge.job_binding_digest,
    v_charge.charge_idempotency_key_sha256,v_charge.merchant_order_id_digest,
    v_charge.amount,'KRW',
    NULL,NULL,
    NULL,NULL,
    NULL,NULL,NULL,
    NULL,NULL,NULL,
    NULL,
    NULL,NULL,NULL,NULL,
    v_now,NULL,NULL,v_audit_id,v_digest,v_now
  );
  RETURN (
    'EXECUTE',(p).provider,(p).event_identity_digest,v_id,v_digest,
    v_charge.root_attempt_id,v_charge.record_digest,v_charge.logical_charge_id,
    v_charge.job_binding_digest,v_charge.charge_idempotency_key_sha256,
    v_charge.merchant_order_id_digest,v_charge.amount::bigint,v_digest,
    v_audit_id
  )::ops.r6e_provider_webhook_claim_receipt_v1;
END
$$;

CREATE FUNCTION ops.release_r6e_provider_webhook_claim_v1(
  p ops.r6e_provider_webhook_release_v1
) RETURNS ops.r6e_payment_transition_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_head ops.provider_webhook_receipts%ROWTYPE;
  v_id uuid:=gen_random_uuid();
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_digest char(64);
  v_audit_id uuid;
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_billing_gateway'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF (p).provider NOT IN ('TOSS_PAYMENTS','KAKAO_PAY','STRIPE')
     OR (p).event_identity_digest !~ '^[0-9a-f]{64}$'
     OR (p).claim_id IS NULL OR (p).claim_digest !~ '^[0-9a-f]{64}$'
     OR (p).safe_code !~ '^[A-Z0-9_]{1,100}$'
     OR (p).release_evidence_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_RELEASE_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_head FROM ops.provider_webhook_receipts
  WHERE provider=(p).provider
    AND provider_event_identity_digest=(p).event_identity_digest
  ORDER BY revision DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  IF v_head.id IS DISTINCT FROM (p).claim_id
     OR v_head.receipt_digest IS DISTINCT FROM (p).claim_digest THEN
    RETURN (
      'CONFLICT',v_head.root_receipt_id,v_head.id,v_head.claim_state,
      v_head.receipt_digest,NULL
    )::ops.r6e_payment_transition_receipt_v1;
  END IF;
  IF v_head.claim_state='RELEASED' THEN
    RETURN (
      CASE WHEN v_head.release_code=(p).safe_code
        AND v_head.release_evidence_digest=(p).release_evidence_digest
        THEN 'REPLAY' ELSE 'CONFLICT' END,
      v_head.root_receipt_id,v_head.id,v_head.claim_state,
      v_head.receipt_digest,NULL
    )::ops.r6e_payment_transition_receipt_v1;
  END IF;
  IF v_head.claim_state<>'CLAIMED' THEN
    RETURN (
      'CONFLICT',v_head.root_receipt_id,v_head.id,v_head.claim_state,
      v_head.receipt_digest,NULL
    )::ops.r6e_payment_transition_receipt_v1;
  END IF;
  v_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'predecessorReceiptDigest',btrim(v_head.receipt_digest),
    'receiptEffect','RELEASE','releaseCode',(p).safe_code,
    'releaseEvidenceDigest',btrim((p).release_evidence_digest),
    'revision',v_head.revision+1,'rootReceiptId',v_head.root_receipt_id
  ));
  v_audit_id:=ops.append_audit_event(
    'provider-webhook:'||v_head.provider||':'
      ||btrim(v_head.provider_event_identity_digest),
    'SERVICE',current_user,NULL,'R6E_PROVIDER_WEBHOOK_RELEASED',
    'ProviderWebhookReceipt',v_head.root_receipt_id::text,
    'payments.webhook','FAILURE',(p).safe_code,gen_random_uuid(),
    jsonb_build_object(
      'receiptDigest',btrim(v_digest),
      'releaseEvidenceDigest',btrim((p).release_evidence_digest)
    )
  );
  INSERT INTO ops.provider_webhook_receipts(
    id,root_receipt_id,revision,receipt_effect,supersedes_receipt_id,
    predecessor_receipt_digest,environment,fixture_authority,provider,
    provider_event_identity_digest,locator_kind,locator_digest,body_digest,
    hint_digest,authentication_state,signature_digest,signed_payload_digest,
    claim_state,claim_request_digest,charge_attempt_id,charge_attempt_digest,
    logical_charge_id,job_binding_digest,charge_idempotency_key_sha256,
    merchant_order_id_digest,amount,currency,release_code,
    release_evidence_digest,provider_payment_state,provider_payment_id_digest,
    provider_fetch_request_digest,provider_fetch_response_digest,
    provider_fetch_digest,payment_fixture_authority,
    test_payment_outcome_config_digest,completion_request_digest,
    provider_observed_at,resulting_charge_attempt_id,
    resulting_charge_attempt_digest,resulting_donation_fact_id,
    resulting_donation_fact_digest,claimed_at,released_at,fetched_at,
    audit_event_id,receipt_digest,recorded_at
  ) SELECT
    v_id,root_receipt_id,revision+1,'RELEASE',id,receipt_digest,environment,
    fixture_authority,provider,provider_event_identity_digest,locator_kind,
    locator_digest,body_digest,hint_digest,authentication_state,
    signature_digest,signed_payload_digest,'RELEASED',claim_request_digest,
    charge_attempt_id,charge_attempt_digest,logical_charge_id,
    job_binding_digest,charge_idempotency_key_sha256,merchant_order_id_digest,
    amount,currency,(p).safe_code,(p).release_evidence_digest,
    NULL,NULL,
    NULL,NULL,NULL,
    NULL,NULL,NULL,
    NULL,
    NULL,NULL,NULL,NULL,
    claimed_at,v_now,NULL,v_audit_id,v_digest,v_now
  FROM ops.provider_webhook_receipts WHERE id=v_head.id;
  RETURN (
    'APPLIED',v_head.root_receipt_id,v_id,'RELEASED',v_digest,v_audit_id
  )::ops.r6e_payment_transition_receipt_v1;
END
$$;

-- Final closed payment ABI.  These definitions deliberately replace the
-- draft bodies above after every input and receipt type is known.  Runtime
-- principals receive EXECUTE only on the wrappers in the ACL block below.
CREATE FUNCTION ops.r6e_donation_intent_request_digest_v1(
  p ops.r6e_donation_intent_claim_v1
) RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
  SELECT ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-donation-intent-claim.v1',
    'requestId',(p).request_id,'provider',(p).provider,
    'merchantAccountHmac',btrim((p).merchant_account_hmac),
    'merchantHmacKeyVersion',(p).merchant_hmac_key_version,
    'donorHmac',btrim((p).donor_hmac),
    'donorGroupHmac',btrim((p).donor_group_hmac),
    'donorHmacKeyVersion',(p).donor_hmac_key_version,
    'offerVersionId',(p).offer_version_id,
    'offerDigest',btrim((p).offer_digest),'tierId',(p).tier_id,
    'cadence',(p).cadence,
    'consentReceiptDigest',btrim((p).consent_receipt_digest),
    'expectedAmountWholeKrw',(p).expected_amount_whole_krw,
    'providerIssueIdempotencyKeyHmac',
      btrim((p).provider_issue_idempotency_key_hmac),
    'providerIssueIdempotencyHmacKeyVersion',
      (p).provider_issue_idempotency_hmac_key_version
  ))
$$;

CREATE FUNCTION ops.r6e_payment_binding_completion_digest_v1(
  p ops.r6e_payment_method_binding_complete_v1
) RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
  SELECT ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-payment-binding-completion.v1',
    'requestId',(p).request_id,'requestDigest',btrim((p).request_digest),
    'donationIntentId',(p).donation_intent_id,'bindingId',(p).binding_id,
    'claimDigest',btrim((p).claim_digest),'provider',(p).provider,
    'providerIssueIdempotencyKeyHmac',
      btrim((p).provider_issue_idempotency_key_hmac),
    'billingKeySecretReference',(p).billing_key_secret_reference,
    'billingKeyHmac',btrim((p).billing_key_hmac),
    'billingKeyHmacKeyVersion',(p).billing_key_hmac_key_version,
    'credentialUsePolicy',(p).credential_use_policy,
    'providerRequestDigest',btrim((p).provider_request_digest),
    'providerResponseDigest',btrim((p).provider_response_digest),
    'providerHttpStatus',(p).provider_http_status
  ))
$$;

CREATE FUNCTION ops.r6e_payment_intent_failure_digest_v1(
  p ops.r6e_donation_intent_fail_v1
) RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
  SELECT ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-donation-intent-failure.v1',
    'requestId',(p).request_id,'requestDigest',btrim((p).request_digest),
    'donationIntentId',(p).donation_intent_id,'bindingId',(p).binding_id,
    'claimDigest',btrim((p).claim_digest),'safeCode',(p).safe_code
  ))
$$;

CREATE FUNCTION ops.r6e_payment_observation_completion_digest_v1(
  p_attempt_id uuid,
  p_claim_digest char(64),
  p_observation ops.r6e_payment_observation_v1,
  p_producer_operation_id text
) RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
  SELECT ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-payment-observation-completion.v1',
    'attemptId',p_attempt_id,'claimDigest',btrim(p_claim_digest),
    'producerOperationId',p_producer_operation_id,
    'provider',(p_observation).provider,
    'providerPaymentIdDigest',
      btrim((p_observation).provider_payment_id_digest),
    'merchantOrderIdDigest',
      btrim((p_observation).merchant_order_id_digest),
    'amountWholeKrw',(p_observation).amount_whole_krw,
    'paymentState',(p_observation).payment_state,
    'providerObservedAt',(p_observation).provider_observed_at,
    'transportRequestDigest',
      btrim((p_observation).transport_request_digest),
    'transportResponseDigest',
      btrim((p_observation).transport_response_digest),
    'providerFetchDigest',btrim((p_observation).provider_fetch_digest),
    'fixtureAuthority',(p_observation).fixture_authority,
    'testPaymentOutcomeConfigDigest',
      btrim((p_observation).test_payment_outcome_config_digest)
  ))
$$;

CREATE FUNCTION ops.r6e_provider_webhook_claim_digest_v1(
  p ops.r6e_provider_webhook_claim_v1
) RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
  SELECT ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-provider-webhook-claim.v1',
    'provider',(p).provider,
    'eventIdentityDigest',btrim((p).event_identity_digest),
    'locatorKind',(p).locator_kind,'locatorDigest',btrim((p).locator_digest),
    'bodyDigest',btrim((p).body_digest),'hintDigest',btrim((p).hint_digest),
    'authenticationState',(p).authentication_state,
    'signatureDigest',CASE WHEN (p).signature_digest IS NULL THEN NULL
      ELSE btrim((p).signature_digest) END,
    'signedPayloadDigest',CASE WHEN (p).signed_payload_digest IS NULL THEN NULL
      ELSE btrim((p).signed_payload_digest) END
  ))
$$;

CREATE FUNCTION ops.r6e_provider_webhook_completion_digest_v1(
  p ops.r6e_provider_webhook_complete_v1
) RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
  SELECT ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-provider-webhook-completion.v1',
    'provider',(p).provider,
    'eventIdentityDigest',btrim((p).event_identity_digest),
    'claimId',(p).claim_id,'claimDigest',btrim((p).claim_digest),
    'observationDigest',btrim(
      ops.r6e_payment_observation_completion_digest_v1(
        ((p).observation).attempt_id,(p).claim_digest,(p).observation,
        'private.ReceivePaymentWebhook'
      )
    )
  ))
$$;

CREATE FUNCTION ops.r6e_provider_webhook_release_digest_v1(
  p ops.r6e_provider_webhook_release_v1
) RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
  SELECT ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-provider-webhook-release.v1',
    'provider',(p).provider,
    'eventIdentityDigest',btrim((p).event_identity_digest),
    'claimId',(p).claim_id,'claimDigest',btrim((p).claim_digest),
    'safeCode',(p).safe_code
  ))
$$;

-- R6E_PAYMENT_WEBHOOK_NOTIFICATION_FINAL

CREATE FUNCTION ops.complete_r6e_provider_webhook_v1(
  p ops.r6e_provider_webhook_complete_v1
) RETURNS ops.r6e_provider_webhook_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
SET timezone='UTC'
AS $$
DECLARE
  v_head ops.provider_webhook_receipts%ROWTYPE;
  v_claim ops.provider_webhook_receipts%ROWTYPE;
  v_charge_root ops.payment_charge_attempts%ROWTYPE;
  v_result_charge ops.payment_charge_attempts%ROWTYPE;
  v_fact ops.donation_facts%ROWTYPE;
  v_terminal ops.r6e_donation_charge_terminal_receipt_v1;
  v_id uuid:=gen_random_uuid();
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_outer_digest char(64);
  v_inner_digest char(64);
  v_receipt_digest char(64);
  v_donation_event_id uuid;
  v_audit_id uuid;
  v_expected_state text;
  v_expected_fact_effect text;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF p IS NULL OR (p).provider IS NULL OR (p).provider NOT IN (
       'TOSS_PAYMENTS','KAKAO_PAY','STRIPE'
     )
     OR (p).event_identity_digest IS NULL
     OR (p).event_identity_digest !~ '^[0-9a-f]{64}$'
     OR (p).claim_id IS NULL
     OR (p).claim_digest IS NULL
     OR (p).claim_digest !~ '^[0-9a-f]{64}$'
     OR (p).observation IS NULL
     OR ((p).observation).provider IS DISTINCT FROM (p).provider
     OR ((p).observation).provider_payment_id_digest IS NULL
     OR ((p).observation).provider_payment_id_digest
       !~ '^[0-9a-f]{64}$'
     OR ((p).observation).merchant_order_id_digest IS NULL
     OR ((p).observation).merchant_order_id_digest
       !~ '^[0-9a-f]{64}$'
     OR ((p).observation).attempt_id IS NULL
     OR ((p).observation).amount_whole_krw IS NULL
     OR ((p).observation).amount_whole_krw<1
     OR ((p).observation).payment_state IS NULL
     OR ((p).observation).payment_state NOT IN (
       'SUCCEEDED','FAILED','CANCELED','PARTIALLY_REFUNDED','REFUNDED'
     )
     OR ((p).observation).provider_observed_at IS NULL
     OR date_trunc('second',((p).observation).provider_observed_at)
       IS DISTINCT FROM ((p).observation).provider_observed_at
     OR ((p).observation).provider_observed_at>v_now
     OR ((p).observation).transport_request_digest IS NULL
     OR ((p).observation).transport_request_digest
       !~ '^[0-9a-f]{64}$'
     OR ((p).observation).transport_response_digest IS NULL
     OR ((p).observation).transport_response_digest
       !~ '^[0-9a-f]{64}$'
     OR ((p).observation).provider_fetch_digest IS NULL
     OR ((p).observation).provider_fetch_digest !~ '^[0-9a-f]{64}$'
     OR ((p).observation).fixture_authority IS DISTINCT FROM 'TEST_FIXTURE'
     OR ((p).observation).test_payment_outcome_config_digest IS NULL
     OR ((p).observation).test_payment_outcome_config_digest
       !~ '^[0-9a-f]{64}$'
     OR (p).completion_request_digest IS NULL
     OR (p).completion_request_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_COMPLETION_INVALID'
      USING ERRCODE='22023';
  END IF;
  v_outer_digest:=ops.r6e_provider_webhook_completion_digest_v1(p);
  IF (p).completion_request_digest IS DISTINCT FROM v_outer_digest THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_COMPLETION_DIGEST_INVALID'
      USING ERRCODE='22023';
  END IF;

  SELECT receipt.* INTO v_head
  FROM ops.provider_webhook_receipts AS receipt
  WHERE receipt.provider=(p).provider
    AND receipt.provider_event_identity_digest=(p).event_identity_digest
  ORDER BY receipt.revision DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_NOT_FOUND'
      USING ERRCODE='P0002';
  END IF;

  IF v_head.claim_state='FETCH_CONFIRMED' THEN
    SELECT receipt.* INTO v_claim
    FROM ops.provider_webhook_receipts AS receipt
    WHERE receipt.id=v_head.supersedes_receipt_id
      AND receipt.receipt_digest=v_head.predecessor_receipt_digest
      AND receipt.claim_state='CLAIMED'
    FOR SHARE;
  ELSE
    v_claim:=v_head;
  END IF;
  IF v_claim.id IS NULL
     OR v_claim.id IS DISTINCT FROM (p).claim_id
     OR v_claim.receipt_digest IS DISTINCT FROM (p).claim_digest THEN
    RETURN (
      'CONFLICT',v_head.provider,v_head.provider_event_identity_digest,
      v_head.receipt_digest,v_head.resulting_charge_attempt_id,
      v_head.resulting_charge_attempt_digest,
      v_head.resulting_donation_fact_id,
      v_head.resulting_donation_fact_digest,NULL,NULL,NULL,
      v_head.audit_event_id
    )::ops.r6e_provider_webhook_receipt_v1;
  END IF;

  SELECT attempt.* INTO v_charge_root
  FROM ops.payment_charge_attempts AS attempt
  WHERE attempt.root_attempt_id=v_claim.charge_attempt_id
    AND attempt.observation_version=1
  FOR SHARE;
  IF NOT FOUND OR NOT EXISTS (
       SELECT 1
       FROM ops.payment_charge_attempts AS claimed_attempt
       WHERE claimed_attempt.root_attempt_id=v_claim.charge_attempt_id
         AND claimed_attempt.record_digest=v_claim.charge_attempt_digest
     ) THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_CHARGE_BINDING_INVALID'
      USING ERRCODE='55000';
  END IF;
  v_inner_digest:=ops.r6e_payment_observation_completion_digest_v1(
    v_charge_root.root_attempt_id,v_charge_root.request_digest,
    (p).observation,'private.ReceivePaymentWebhook'
  );
  v_expected_state:=CASE ((p).observation).payment_state
    WHEN 'CANCELED' THEN 'FAILED'
    WHEN 'PARTIALLY_REFUNDED' THEN 'RECONCILIATION_REQUIRED'
    ELSE ((p).observation).payment_state
  END;
  v_expected_fact_effect:=CASE ((p).observation).payment_state
    WHEN 'SUCCEEDED' THEN 'ORIGINAL'
    WHEN 'REFUNDED' THEN 'REVERSAL'
    ELSE NULL
  END;

  IF v_head.claim_state='FETCH_CONFIRMED' THEN
    IF v_head.provider_payment_state IN ('FAILED','CANCELED') THEN
      -- Those outcomes cannot have a finalized webhook receipt until the
      -- PAYMENT_REVIEW notification authority is decision-complete.  Do not
      -- revive a legacy row through the replay path.
      RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_AUTHORIZATION_NOT_CURRENT'
        USING ERRCODE='55000';
    END IF;
    v_receipt_digest:=ops.r6e_payment_sha256_jsonb_v1(
      jsonb_build_object(
        'schemaVersion','r6e-provider-webhook-receipt.v1',
        'rootReceiptId',v_head.root_receipt_id,
        'revision',v_head.revision,'receiptEffect','FETCH',
        'supersedesReceiptId',v_head.supersedes_receipt_id,
        'predecessorReceiptDigest',btrim(
          v_head.predecessor_receipt_digest
        ),
        'provider',v_head.provider,
        'eventIdentityDigest',btrim(
          v_head.provider_event_identity_digest
        ),
        'claimRequestDigest',btrim(v_head.claim_request_digest),
        'completionRequestDigest',btrim(
          v_head.completion_request_digest
        ),
        'providerPaymentState',v_head.provider_payment_state,
        'providerPaymentIdDigest',btrim(
          v_head.provider_payment_id_digest
        ),
        'providerFetchRequestDigest',btrim(
          v_head.provider_fetch_request_digest
        ),
        'providerFetchResponseDigest',btrim(
          v_head.provider_fetch_response_digest
        ),
        'providerFetchDigest',btrim(v_head.provider_fetch_digest),
        'paymentFixtureAuthority',v_head.payment_fixture_authority,
        'testPaymentOutcomeConfigDigest',btrim(
          v_head.test_payment_outcome_config_digest
        ),
        'providerObservedAt',v_head.provider_observed_at,
        'resultingChargeAttemptId',v_head.resulting_charge_attempt_id,
        'resultingChargeAttemptDigest',btrim(
          v_head.resulting_charge_attempt_digest
        ),
        'resultingDonationFactId',v_head.resulting_donation_fact_id,
        'resultingDonationFactDigest',CASE
          WHEN v_head.resulting_donation_fact_digest IS NULL THEN NULL
          ELSE btrim(v_head.resulting_donation_fact_digest)
        END,
        'fetchedAt',v_head.fetched_at
      )
    );
    IF v_head.receipt_effect IS DISTINCT FROM 'FETCH'
       OR v_head.receipt_digest IS DISTINCT FROM v_receipt_digest
       OR v_head.completion_request_digest IS DISTINCT FROM
         (p).completion_request_digest
       OR v_head.charge_attempt_id IS DISTINCT FROM
         ((p).observation).attempt_id
       OR v_head.provider_payment_state IS DISTINCT FROM
         ((p).observation).payment_state
       OR v_head.provider_payment_id_digest IS DISTINCT FROM
         ((p).observation).provider_payment_id_digest
       OR v_head.merchant_order_id_digest IS DISTINCT FROM
         ((p).observation).merchant_order_id_digest
       OR v_head.amount IS DISTINCT FROM
         ((p).observation).amount_whole_krw::numeric
       OR v_head.provider_fetch_request_digest IS DISTINCT FROM
         ((p).observation).transport_request_digest
       OR v_head.provider_fetch_response_digest IS DISTINCT FROM
         ((p).observation).transport_response_digest
       OR v_head.provider_fetch_digest IS DISTINCT FROM
         ((p).observation).provider_fetch_digest
       OR v_head.payment_fixture_authority IS DISTINCT FROM
         ((p).observation).fixture_authority
       OR v_head.test_payment_outcome_config_digest IS DISTINCT FROM
         ((p).observation).test_payment_outcome_config_digest
       OR v_head.provider_observed_at IS DISTINCT FROM
         ((p).observation).provider_observed_at THEN
      RETURN (
        'CONFLICT',v_head.provider,v_head.provider_event_identity_digest,
        v_head.receipt_digest,v_head.resulting_charge_attempt_id,
        v_head.resulting_charge_attempt_digest,
        v_head.resulting_donation_fact_id,
        v_head.resulting_donation_fact_digest,NULL,NULL,NULL,
        v_head.audit_event_id
      )::ops.r6e_provider_webhook_receipt_v1;
    END IF;
    SELECT attempt.* INTO v_result_charge
    FROM ops.payment_charge_attempts AS attempt
    WHERE attempt.root_attempt_id=v_head.resulting_charge_attempt_id
      AND attempt.record_digest=v_head.resulting_charge_attempt_digest
    FOR SHARE;
    IF NOT FOUND
       OR v_result_charge.attempt_state IS DISTINCT FROM v_expected_state
       OR v_result_charge.producer_operation_id IS DISTINCT FROM
         'private.ReceivePaymentWebhook'
       OR v_result_charge.completion_request_digest IS DISTINCT FROM
         v_inner_digest
       OR v_result_charge.provider_observed_state IS DISTINCT FROM
         v_head.provider_payment_state
       OR v_result_charge.provider_payment_id_digest IS DISTINCT FROM
         v_head.provider_payment_id_digest
       OR v_result_charge.merchant_order_id_digest IS DISTINCT FROM
         v_head.merchant_order_id_digest
       OR v_result_charge.amount IS DISTINCT FROM v_head.amount
       OR v_result_charge.provider_transport_request_digest IS DISTINCT FROM
         v_head.provider_fetch_request_digest
       OR v_result_charge.provider_transport_response_digest IS DISTINCT FROM
         v_head.provider_fetch_response_digest
       OR v_result_charge.provider_fetch_digest IS DISTINCT FROM
         v_head.provider_fetch_digest
       OR v_result_charge.fixture_authority IS DISTINCT FROM
         v_head.payment_fixture_authority
       OR v_result_charge.test_payment_outcome_config_digest IS DISTINCT FROM
         v_head.test_payment_outcome_config_digest
       OR v_result_charge.provider_observed_at IS DISTINCT FROM
         v_head.provider_observed_at
       OR ((p).observation).payment_state='PARTIALLY_REFUNDED' AND (
         v_result_charge.terminal_authority IS NOT NULL
         OR v_result_charge.reconciliation_reason IS DISTINCT FROM
           'PARTIAL_REFUND_AMOUNT_UNAVAILABLE'
         OR v_result_charge.reconciliation_evidence_digest IS DISTINCT FROM
           v_head.provider_fetch_digest
       )
       OR ((p).observation).payment_state<>'PARTIALLY_REFUNDED' AND (
         v_result_charge.terminal_authority IS DISTINCT FROM
           'PROVIDER_FETCH_CONFIRMED'
         OR v_result_charge.reconciliation_reason IS NOT NULL
         OR v_result_charge.reconciliation_evidence_digest IS NOT NULL
       ) THEN
      RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_RESULT_BINDING_INVALID'
        USING ERRCODE='55000';
    END IF;

    IF v_expected_fact_effect IS NOT NULL THEN
      IF num_nonnulls(
           v_head.resulting_donation_fact_id,
           v_head.resulting_donation_fact_digest
         )<>2 THEN
        RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_DONATION_BINDING_INVALID'
          USING ERRCODE='55000';
      END IF;
      SELECT fact.* INTO v_fact
      FROM ops.donation_facts AS fact
      WHERE fact.id=v_head.resulting_donation_fact_id
        AND fact.fact_digest=v_head.resulting_donation_fact_digest
        AND fact.payment_charge_attempt_id=
          v_head.resulting_charge_attempt_id
        AND fact.payment_charge_attempt_digest=
          v_head.resulting_charge_attempt_digest
      FOR SHARE;
      IF NOT FOUND
         OR v_fact.fact_effect IS DISTINCT FROM v_expected_fact_effect
         OR v_fact.provider_fetch_digest IS DISTINCT FROM
           v_head.provider_fetch_digest
         OR v_fact.recognized_at IS DISTINCT FROM
           v_result_charge.terminal_at
         OR v_fact.funding_source_kind IS DISTINCT FROM 'DONATION'
         OR v_fact.investigation_exemption IS DISTINCT FROM false
         OR v_fact.access_entitlement_granted IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_DONATION_BINDING_INVALID'
          USING ERRCODE='55000';
      END IF;
      SELECT event.id INTO v_donation_event_id
      FROM ops.outbox AS event
      WHERE event.aggregate_type='DonationFact'
        AND event.aggregate_id=v_fact.root_fact_id::text
        AND event.aggregate_version=v_fact.revision
        AND event.event_type='donation.fact_recorded.v1';
      IF v_donation_event_id IS NULL THEN
        RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_DONATION_EVENT_MISSING'
          USING ERRCODE='55000';
      END IF;
    ELSIF num_nonnulls(
      v_head.resulting_donation_fact_id,
      v_head.resulting_donation_fact_digest
    )<>0 THEN
      RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_DONATION_BINDING_INVALID'
        USING ERRCODE='55000';
    END IF;

    IF EXISTS (
      SELECT 1 FROM ops.tasks AS task
      WHERE task.task_type='PAYMENT_REVIEW'
        AND task.payment_review_source_kind='DONATION_PAYMENT_FAILURE'
        AND task.payment_review_source_receipt_id=
          v_head.resulting_charge_attempt_id
        AND task.payment_review_source_receipt_digest=
          v_head.resulting_charge_attempt_digest
    ) THEN
      RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_REVIEW_BINDING_INVALID'
        USING ERRCODE='55000';
    END IF;
    RETURN (
      'REPLAY',v_head.provider,v_head.provider_event_identity_digest,
      v_head.receipt_digest,v_head.resulting_charge_attempt_id,
      v_head.resulting_charge_attempt_digest,
      v_head.resulting_donation_fact_id,
      v_head.resulting_donation_fact_digest,v_donation_event_id,
      NULL,NULL,v_head.audit_event_id
    )::ops.r6e_provider_webhook_receipt_v1;
  END IF;

  IF v_head.claim_state IS DISTINCT FROM 'CLAIMED'
     OR v_head.id IS DISTINCT FROM (p).claim_id
     OR v_head.receipt_digest IS DISTINCT FROM (p).claim_digest
     OR v_head.charge_attempt_id IS DISTINCT FROM
       ((p).observation).attempt_id
     OR v_head.provider IS DISTINCT FROM ((p).observation).provider
     OR v_head.merchant_order_id_digest IS DISTINCT FROM
       ((p).observation).merchant_order_id_digest
     OR v_head.amount IS DISTINCT FROM
       ((p).observation).amount_whole_krw::numeric
     OR v_charge_root.expected_provider_payment_id_digest IS DISTINCT FROM
       ((p).observation).provider_payment_id_digest
     OR ((p).observation).provider_observed_at<v_charge_root.requested_at THEN
    RETURN (
      'CONFLICT',v_head.provider,v_head.provider_event_identity_digest,
      v_head.receipt_digest,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
      v_head.audit_event_id
    )::ops.r6e_provider_webhook_receipt_v1;
  END IF;

  PERFORM set_config(
    'gurine.payment_producer_operation','private.ReceivePaymentWebhook',true
  );
  v_terminal:=ops.apply_r6e_payment_observation_v1(
    v_charge_root.root_attempt_id,(p).observation,v_inner_digest
  );
  IF ((p).observation).payment_state IN ('FAILED','CANCELED') THEN
    -- apply_r6e_payment_observation_v1 currently raises this before its first
    -- write.  Preserve the same fail-closed result if that implementation is
    -- ever weakened; this exception rolls back every wrapper-side mutation.
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_AUTHORIZATION_NOT_CURRENT'
      USING ERRCODE='55000';
  END IF;
  IF (v_terminal).disposition IS NULL
     OR (v_terminal).disposition NOT IN (
       'APPLIED','REPLAY','RECONCILIATION_REQUIRED'
     ) THEN
    RETURN (
      'CONFLICT',v_head.provider,v_head.provider_event_identity_digest,
      v_head.receipt_digest,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
      v_head.audit_event_id
    )::ops.r6e_provider_webhook_receipt_v1;
  END IF;

  IF (v_terminal).attempt_id IS DISTINCT FROM v_charge_root.root_attempt_id
     OR (v_terminal).state IS DISTINCT FROM v_expected_state
     OR (v_terminal).receipt_digest IS NULL
     OR (v_terminal).producer_operation_id IS DISTINCT FROM
       'private.ReceivePaymentWebhook'
     OR (v_terminal).effects IS DISTINCT FROM 'NONE'
     OR (v_terminal).fixture_authority IS DISTINCT FROM
       ((p).observation).fixture_authority
     OR (v_terminal).test_payment_outcome_config_digest IS DISTINCT FROM
       ((p).observation).test_payment_outcome_config_digest
     OR ((p).observation).payment_state='PARTIALLY_REFUNDED'
       AND (v_terminal).terminal_authority IS NOT NULL
     OR ((p).observation).payment_state<>'PARTIALLY_REFUNDED'
       AND (v_terminal).terminal_authority IS DISTINCT FROM
         'PROVIDER_FETCH_CONFIRMED'
     OR ((p).observation).payment_state='PARTIALLY_REFUNDED' AND (
       num_nonnulls(
         (v_terminal).donation_fact_id,
         (v_terminal).donation_fact_digest,
         (v_terminal).donation_outbox_event_id,
         (v_terminal).review_task_id,
         (v_terminal).review_notification_intent_id,
         (v_terminal).review_outbox_event_id
       )<>0
     )
     OR v_expected_fact_effect IS NOT NULL AND (
       (v_terminal).donation_fact_effect IS DISTINCT FROM
         v_expected_fact_effect
       OR (v_terminal).donation_fact_id IS NULL
       OR (v_terminal).donation_fact_digest IS NULL
       OR (v_terminal).donation_outbox_event_id IS NULL
       OR num_nonnulls(
         (v_terminal).review_task_id,
         (v_terminal).review_notification_intent_id,
         (v_terminal).review_outbox_event_id
       )<>0
     )
     THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_EFFECT_BOUNDARY_INVALID'
      USING ERRCODE='55000';
  END IF;
  SELECT attempt.* INTO v_result_charge
  FROM ops.payment_charge_attempts AS attempt
  WHERE attempt.root_attempt_id=(v_terminal).attempt_id
    AND attempt.record_digest=(v_terminal).receipt_digest
  FOR SHARE;
  IF NOT FOUND
     OR v_result_charge.attempt_state IS DISTINCT FROM v_expected_state
     OR v_result_charge.producer_operation_id IS DISTINCT FROM
       'private.ReceivePaymentWebhook'
     OR v_result_charge.completion_request_digest IS DISTINCT FROM
       v_inner_digest
     OR v_result_charge.provider_observed_state IS DISTINCT FROM
       ((p).observation).payment_state
     OR v_result_charge.provider_payment_id_digest IS DISTINCT FROM
       ((p).observation).provider_payment_id_digest
     OR v_result_charge.provider_transport_request_digest IS DISTINCT FROM
       ((p).observation).transport_request_digest
     OR v_result_charge.provider_transport_response_digest IS DISTINCT FROM
       ((p).observation).transport_response_digest
     OR v_result_charge.provider_fetch_digest IS DISTINCT FROM
       ((p).observation).provider_fetch_digest
     OR v_result_charge.fixture_authority IS DISTINCT FROM
       ((p).observation).fixture_authority
     OR v_result_charge.test_payment_outcome_config_digest IS DISTINCT FROM
       ((p).observation).test_payment_outcome_config_digest
     OR v_result_charge.provider_observed_at IS DISTINCT FROM
       ((p).observation).provider_observed_at THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_RESULT_BINDING_INVALID'
      USING ERRCODE='55000';
  END IF;

  v_receipt_digest:=ops.r6e_payment_sha256_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-provider-webhook-receipt.v1',
      'rootReceiptId',v_head.root_receipt_id,
      'revision',v_head.revision+1,'receiptEffect','FETCH',
      'supersedesReceiptId',v_head.id,
      'predecessorReceiptDigest',btrim(v_head.receipt_digest),
      'provider',v_head.provider,
      'eventIdentityDigest',btrim(v_head.provider_event_identity_digest),
      'claimRequestDigest',btrim(v_head.claim_request_digest),
      'completionRequestDigest',btrim((p).completion_request_digest),
      'providerPaymentState',((p).observation).payment_state,
      'providerPaymentIdDigest',btrim(
        ((p).observation).provider_payment_id_digest
      ),
      'providerFetchRequestDigest',btrim(
        ((p).observation).transport_request_digest
      ),
      'providerFetchResponseDigest',btrim(
        ((p).observation).transport_response_digest
      ),
      'providerFetchDigest',btrim(
        ((p).observation).provider_fetch_digest
      ),
      'paymentFixtureAuthority',((p).observation).fixture_authority,
      'testPaymentOutcomeConfigDigest',btrim(
        ((p).observation).test_payment_outcome_config_digest
      ),
      'providerObservedAt',((p).observation).provider_observed_at,
      'resultingChargeAttemptId',(v_terminal).attempt_id,
      'resultingChargeAttemptDigest',btrim((v_terminal).receipt_digest),
      'resultingDonationFactId',(v_terminal).donation_fact_id,
      'resultingDonationFactDigest',CASE
        WHEN (v_terminal).donation_fact_digest IS NULL THEN NULL
        ELSE btrim((v_terminal).donation_fact_digest)
      END,
      'fetchedAt',v_now
    )
  );
  v_audit_id:=ops.append_audit_event(
    'provider-webhook:'||v_head.provider||':'
      ||btrim(v_head.provider_event_identity_digest),
    'SERVICE',current_user,NULL,'R6E_PROVIDER_WEBHOOK_FETCH_CONFIRMED',
    'ProviderWebhookReceipt',v_head.root_receipt_id::text,
    'payments.webhook','SUCCESS','authoritative provider fetch confirmed',
    gen_random_uuid(),jsonb_build_object(
      'providerPaymentState',((p).observation).payment_state,
      'providerFetchDigest',btrim(
        ((p).observation).provider_fetch_digest
      ),
      'resultingChargeAttemptDigest',btrim((v_terminal).receipt_digest),
      'resultingDonationFactDigest',CASE
        WHEN (v_terminal).donation_fact_digest IS NULL THEN NULL
        ELSE btrim((v_terminal).donation_fact_digest)
      END,
      'receiptDigest',btrim(v_receipt_digest)
    )
  );
  INSERT INTO ops.provider_webhook_receipts(
    id,root_receipt_id,revision,receipt_effect,supersedes_receipt_id,
    predecessor_receipt_digest,environment,fixture_authority,provider,
    provider_event_identity_digest,locator_kind,locator_digest,body_digest,
    hint_digest,authentication_state,signature_digest,signed_payload_digest,
    claim_state,claim_request_digest,charge_attempt_id,charge_attempt_digest,
    logical_charge_id,job_binding_digest,charge_idempotency_key_sha256,
    merchant_order_id_digest,amount,currency,release_code,
    release_evidence_digest,provider_payment_state,provider_payment_id_digest,
    provider_fetch_request_digest,provider_fetch_response_digest,
    provider_fetch_digest,payment_fixture_authority,
    test_payment_outcome_config_digest,completion_request_digest,
    provider_observed_at,resulting_charge_attempt_id,
    resulting_charge_attempt_digest,resulting_donation_fact_id,
    resulting_donation_fact_digest,claimed_at,released_at,fetched_at,
    audit_event_id,receipt_digest,recorded_at
  ) SELECT
    v_id,root_receipt_id,revision+1,'FETCH',id,receipt_digest,environment,
    fixture_authority,provider,provider_event_identity_digest,locator_kind,
    locator_digest,body_digest,hint_digest,authentication_state,
    signature_digest,signed_payload_digest,'FETCH_CONFIRMED',
    claim_request_digest,charge_attempt_id,charge_attempt_digest,
    logical_charge_id,job_binding_digest,charge_idempotency_key_sha256,
    merchant_order_id_digest,amount,currency,NULL,NULL,
    ((p).observation).payment_state,
    ((p).observation).provider_payment_id_digest,
    ((p).observation).transport_request_digest,
    ((p).observation).transport_response_digest,
    ((p).observation).provider_fetch_digest,
    ((p).observation).fixture_authority,
    ((p).observation).test_payment_outcome_config_digest,
    (p).completion_request_digest,
    ((p).observation).provider_observed_at,(v_terminal).attempt_id,
    (v_terminal).receipt_digest,(v_terminal).donation_fact_id,
    (v_terminal).donation_fact_digest,claimed_at,NULL,v_now,v_audit_id,
    v_receipt_digest,v_now
  FROM ops.provider_webhook_receipts
  WHERE id=v_head.id AND receipt_digest=v_head.receipt_digest;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PROVIDER_WEBHOOK_CLAIM_STALE'
      USING ERRCODE='40001';
  END IF;
  RETURN (
    'APPLIED',v_head.provider,v_head.provider_event_identity_digest,
    v_receipt_digest,(v_terminal).attempt_id,(v_terminal).receipt_digest,
    (v_terminal).donation_fact_id,(v_terminal).donation_fact_digest,
    (v_terminal).donation_outbox_event_id,
    (v_terminal).review_notification_intent_id,
    (v_terminal).review_outbox_event_id,v_audit_id
  )::ops.r6e_provider_webhook_receipt_v1;
END
$$;

ALTER FUNCTION ops.complete_r6e_provider_webhook_v1(
  ops.r6e_provider_webhook_complete_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.complete_r6e_provider_webhook_v1(
  ops.r6e_provider_webhook_complete_v1
) FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_public_projector,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_economics_importer;
GRANT EXECUTE ON FUNCTION ops.complete_r6e_provider_webhook_v1(
  ops.r6e_provider_webhook_complete_v1
) TO gurine_billing_gateway;
REVOKE ALL ON TYPE ops.r6e_provider_webhook_complete_v1,
  ops.r6e_provider_webhook_receipt_v1,ops.r6e_payment_observation_v1
FROM PUBLIC;
GRANT USAGE ON TYPE ops.r6e_provider_webhook_complete_v1,
  ops.r6e_provider_webhook_receipt_v1,ops.r6e_payment_observation_v1
TO gurine_billing_gateway;

CREATE OR REPLACE FUNCTION ops.materialize_payment_review_notification_v1(
  p ops.payment_review_notification_materialize_v1
) RETURNS ops.payment_review_notification_materialize_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
SET timezone='UTC'
AS $r6e_payment_review_materializer$
DECLARE
  v_event ops.outbox%ROWTYPE;
  v_task ops.tasks%ROWTYPE;
  v_intent ops.communication_intents%ROWTYPE;
  v_authority ops.r6e_payment_review_authority_v1;
  v_payload_version bigint;
  v_payload_occurred_at timestamptz;
  v_task_digest char(64);
  v_topic_scope jsonb;
  v_topic_digest char(64);
  v_policy_snapshot_digest char(64);
  v_intent_digest char(64);
  v_creation_receipt_digest char(64);
  v_request_digest char(64);
  v_transition_digest char(64);
BEGIN
  IF session_user<>'gurine_notification_worker'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_NOTIFICATION_WORKER_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF p IS NULL
     OR (p).event_id IS NULL
     OR (p).review_task_id IS NULL
     OR (p).review_task_version IS NULL
     OR (p).review_task_version<1
     OR (p).review_task_digest IS NULL
     OR (p).review_task_digest !~ '^[0-9a-f]{64}$'
     OR (p).source_kind IS NULL
     OR (p).source_kind NOT IN (
       'DONATION_PAYMENT_FAILURE','SIGNED_COLLECTION_FAILURE'
     )
     OR (p).source_receipt_id IS NULL
     OR (p).source_receipt_digest IS NULL
     OR (p).source_receipt_digest !~ '^[0-9a-f]{64}$'
     OR (p).occurred_at IS NULL THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_MATERIALIZATION_INVALID'
      USING ERRCODE='22023';
  END IF;

  SELECT event.* INTO v_event
  FROM ops.outbox AS event
  WHERE event.id=(p).event_id
  FOR SHARE;
  IF NOT FOUND
     OR v_event.event_type IS DISTINCT FROM
       'notification.payment_review_requested.v1'
     OR v_event.aggregate_type IS DISTINCT FROM 'payment_review_task'
     OR v_event.aggregate_id IS DISTINCT FROM (p).review_task_id::text
     OR v_event.aggregate_version IS DISTINCT FROM (p).review_task_version
     OR v_event.occurred_at IS DISTINCT FROM (p).occurred_at
     OR jsonb_typeof(v_event.payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_EVENT_BINDING_INVALID'
      USING ERRCODE='23514';
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(v_event.payload))<>7
     OR NOT v_event.payload?&ARRAY[
       'reviewTaskId','reviewTaskVersion','reviewTaskDigest','sourceKind',
       'sourceReceiptId','sourceReceiptDigest','occurredAt'
     ]
     OR jsonb_typeof(v_event.payload->'reviewTaskId')
       IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_event.payload->'reviewTaskVersion')
       IS DISTINCT FROM 'number'
     OR jsonb_typeof(v_event.payload->'reviewTaskDigest')
       IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_event.payload->'sourceKind')
       IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_event.payload->'sourceReceiptId')
       IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_event.payload->'sourceReceiptDigest')
       IS DISTINCT FROM 'string'
     OR jsonb_typeof(v_event.payload->'occurredAt')
       IS DISTINCT FROM 'string' THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_EVENT_BINDING_INVALID'
      USING ERRCODE='23514';
  END IF;
  BEGIN
    v_payload_version:=(v_event.payload->>'reviewTaskVersion')::bigint;
    v_payload_occurred_at:=(v_event.payload->>'occurredAt')::timestamptz;
  EXCEPTION WHEN data_exception THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_EVENT_BINDING_INVALID'
      USING ERRCODE='23514';
  END;
  IF v_event.payload->>'reviewTaskId' IS DISTINCT FROM
       (p).review_task_id::text
     OR v_payload_version IS DISTINCT FROM (p).review_task_version
     OR v_event.payload->>'reviewTaskDigest' IS DISTINCT FROM
       btrim((p).review_task_digest)
     OR v_event.payload->>'sourceKind' IS DISTINCT FROM (p).source_kind
     OR v_event.payload->>'sourceReceiptId' IS DISTINCT FROM
       (p).source_receipt_id::text
     OR v_event.payload->>'sourceReceiptDigest' IS DISTINCT FROM
       btrim((p).source_receipt_digest)
     OR v_payload_occurred_at IS DISTINCT FROM (p).occurred_at
  THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_EVENT_BINDING_INVALID'
      USING ERRCODE='23514';
  END IF;

  SELECT task.* INTO v_task
  FROM ops.tasks AS task
  WHERE task.id=(p).review_task_id
    AND task.task_type='PAYMENT_REVIEW'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_TASK_BINDING_INVALID'
      USING ERRCODE='23514';
  END IF;
  v_task_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-payment-review-task.v1',
    'assigneeUserId',v_task.assignee_user_id,
    'dueAt',v_task.due_at,'occurredAt',v_task.created_at,
    'reasonDigest',CASE WHEN v_task.payment_review_reason_digest IS NULL
      THEN NULL ELSE btrim(v_task.payment_review_reason_digest) END,
    'reviewTaskId',v_task.id,
    'sourceKind',v_task.payment_review_source_kind,
    'sourceReceiptDigest',CASE
      WHEN v_task.payment_review_source_receipt_digest IS NULL THEN NULL
      ELSE btrim(v_task.payment_review_source_receipt_digest) END,
    'sourceReceiptId',v_task.payment_review_source_receipt_id,
    'executionId',v_task.payment_review_execution_id,
    'executionGeneration',v_task.payment_review_execution_generation,
    'actionDetailDigest',CASE
      WHEN v_task.payment_review_action_detail_digest IS NULL THEN NULL
      ELSE btrim(v_task.payment_review_action_detail_digest) END,
    'version',v_task.version
  ));
  IF v_task.version IS DISTINCT FROM (p).review_task_version
     OR v_task.creation_digest IS DISTINCT FROM (p).review_task_digest
     OR v_task.creation_digest IS DISTINCT FROM v_task_digest
     OR v_task.object_type IS DISTINCT FROM 'PAYMENT_RECEIPT'
     OR v_task.object_id IS DISTINCT FROM (p).source_receipt_id
     OR v_task.assignee_user_id IS NULL
     OR v_task.due_at IS NULL
     OR v_task.due_at<=v_task.created_at
     OR v_task.created_at IS DISTINCT FROM (p).occurred_at
     OR v_task.payment_review_source_kind IS DISTINCT FROM (p).source_kind
     OR v_task.payment_review_source_receipt_id IS DISTINCT FROM
       (p).source_receipt_id
     OR v_task.payment_review_source_receipt_digest IS DISTINCT FROM
       (p).source_receipt_digest
     OR v_task.payment_review_notification_intent_id IS NULL
     OR ((p).source_kind='DONATION_PAYMENT_FAILURE' AND num_nonnulls(
       v_task.payment_review_execution_id,
       v_task.payment_review_execution_generation,
       v_task.payment_review_action_detail_digest
     )<>0)
     OR ((p).source_kind='SIGNED_COLLECTION_FAILURE' AND (
       v_task.payment_review_execution_id IS NULL
       OR v_task.payment_review_execution_generation IS NULL
       OR v_task.payment_review_execution_generation<1
       OR v_task.payment_review_action_detail_digest IS NULL
       OR v_task.payment_review_action_detail_digest
         !~ '^[0-9a-f]{64}$'
     )) THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_TASK_BINDING_INVALID'
      USING ERRCODE='23514';
  END IF;
  IF ops.r6e_payment_review_source_is_authoritative_v1(
       (p).source_kind,(p).source_receipt_id,(p).source_receipt_digest
     ) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_SOURCE_NOT_AUTHORITATIVE'
      USING ERRCODE='23514';
  END IF;

  v_authority:=ops.resolve_r6e_payment_review_authority_v1(
    v_task.assignee_user_id
  );
  IF (v_authority).assignee_user_id IS DISTINCT FROM
       v_task.assignee_user_id
     OR (v_authority).subject_id IS NULL
     OR (v_authority).authorization_event_id IS NULL
     OR (v_authority).authorization_receipt_digest IS NULL
     OR (v_authority).authorization_receipt_digest
       !~ '^[0-9a-f]{64}$'
     OR NULLIF(btrim((v_authority).policy_version),'') IS NULL
     OR (v_authority).policy_digest IS NULL
     OR (v_authority).policy_digest !~ '^[0-9a-f]{64}$'
     OR (v_authority).subject_origin_binding_digest IS NULL
     OR (v_authority).subject_origin_binding_digest
       !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_AUTHORITY_INVALID'
      USING ERRCODE='23514';
  END IF;
  v_topic_scope:=jsonb_build_object(
    'reviewTaskId',v_task.id,
    'sourceKind',v_task.payment_review_source_kind
  );
  v_topic_digest:=ops.communication_topic_scope_digest(v_topic_scope);
  v_policy_snapshot_digest:=ops.r6e_payment_sha256_jsonb_v1(
    jsonb_build_object(
      'authorizationEventId',(v_authority).authorization_event_id,
      'authorizationReceiptDigest',btrim(
        (v_authority).authorization_receipt_digest
      ),
      'policyDigest',btrim((v_authority).policy_digest),
      'policyVersion',(v_authority).policy_version,
      'subjectOriginBindingDigest',btrim(
        (v_authority).subject_origin_binding_digest
      )
    )
  );

  SELECT intent.* INTO v_intent
  FROM ops.communication_intents AS intent
  WHERE intent.id=v_task.payment_review_notification_intent_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_INTENT_BINDING_INVALID'
      USING ERRCODE='23514';
  END IF;
  v_intent_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'intentId',v_intent.id,
    'reviewTaskDigest',btrim(v_task.creation_digest),
    'reviewTaskId',v_task.id,
    'topicScopeDigest',btrim(v_topic_digest),
    'recipientSubjectId',(v_authority).subject_id,
    'sourceDecisionDigest',btrim(
      (v_authority).authorization_receipt_digest
    )
  ));
  v_creation_receipt_digest:=ops.r6e_payment_sha256_jsonb_v1(
    jsonb_build_object(
      'intentDigest',btrim(v_intent_digest),
      'sourceEventId',(p).event_id,
      'version',1
    )
  );
  v_request_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'eventId',(p).event_id,
    'intentDigest',btrim(v_intent_digest),
    'intentId',v_intent.id,
    'reviewTaskDigest',btrim(v_task.creation_digest),
    'reviewTaskId',v_task.id
  ));
  v_transition_digest:=encode(extensions.digest(convert_to(
    'INTENT-MATERIALIZED:'||v_intent.id::text||':2:'||v_request_digest,
    'UTF8'
  ),'sha256'),'hex');
  IF NULLIF(btrim(v_intent.deployment_id),'') IS NULL
     OR v_intent.logical_intent_digest IS DISTINCT FROM v_intent_digest
     OR v_intent.source_event_id IS DISTINCT FROM (p).event_id
     OR v_intent.source_event_type IS DISTINCT FROM
       'notification.payment_review_requested.v1'
     OR v_intent.source_object_type IS DISTINCT FROM 'PAYMENT_REVIEW_TASK'
     OR v_intent.source_object_id IS DISTINCT FROM v_task.id
     OR v_intent.material_event_version IS DISTINCT FROM v_task.version
     OR v_intent.communication_class IS DISTINCT FROM
       'INTERNAL_ACTION_REQUEST'
     OR v_intent.purpose IS DISTINCT FROM 'INTERNAL_ACTION_REQUEST'
     OR v_intent.topic_scope IS DISTINCT FROM v_topic_scope
     OR v_intent.topic_scope_digest IS DISTINCT FROM v_topic_digest
     OR v_intent.recipient_subject_id IS DISTINCT FROM
       (v_authority).subject_id
     OR v_intent.audience_policy_version IS DISTINCT FROM
       (v_authority).policy_version
     OR v_intent.audience_policy_digest IS DISTINCT FROM
       (v_authority).policy_digest
     OR v_intent.policy_snapshot_digest IS DISTINCT FROM
       v_policy_snapshot_digest
     OR v_intent.effect_safety_class IS DISTINCT FROM
       'DUPLICATION_SENSITIVE'
     OR v_intent.source_decision_receipt_id IS DISTINCT FROM
       (v_authority).authorization_event_id
     OR v_intent.source_decision_digest IS DISTINCT FROM
       (v_authority).authorization_receipt_digest
     OR v_intent.intent_digest IS DISTINCT FROM v_intent_digest
     OR v_intent.creation_receipt_digest IS DISTINCT FROM
       v_creation_receipt_digest
     OR v_intent.created_at IS DISTINCT FROM (p).occurred_at
     OR NOT (
       v_intent.state='CREATED'
       AND v_intent.version=1
       AND v_intent.transition_receipt_digest IS NULL
       AND v_intent.materialized_at IS NULL
       OR v_intent.state='MATERIALIZED'
       AND v_intent.version=2
       AND v_intent.transition_receipt_digest=v_transition_digest
       AND v_intent.materialized_at IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_INTENT_BINDING_INVALID'
      USING ERRCODE='23514';
  END IF;

  -- The active communication contract has neither an exact PAYMENT_REVIEW
  -- topic variant nor an authoritative deployment binding.  A purpose-only
  -- authorization must never be upgraded into a sendable task notification.
  -- Keep the fully validated legacy row readable, but stop before the nested
  -- materializer (the first write) until the higher contract closes both
  -- authorities.
  RAISE EXCEPTION 'R6E_PAYMENT_REVIEW_AUTHORIZATION_NOT_CURRENT'
    USING ERRCODE='55000';
END
$r6e_payment_review_materializer$;

ALTER FUNCTION ops.materialize_payment_review_notification_v1(
  ops.payment_review_notification_materialize_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.materialize_payment_review_notification_v1(
  ops.payment_review_notification_materialize_v1
) FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_submission_api,gurine_ingest_worker,
  gurine_public_projector,gurine_scheduler,gurine_document_extractor,
  gurine_identity_api,gurine_auditor,gurine_billing_gateway,
  gurine_economics_importer;
GRANT EXECUTE ON FUNCTION ops.materialize_payment_review_notification_v1(
  ops.payment_review_notification_materialize_v1
) TO gurine_notification_worker;
REVOKE ALL ON TYPE ops.payment_review_notification_materialize_v1,
  ops.payment_review_notification_materialize_receipt_v1
FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_submission_api,gurine_ingest_worker,
  gurine_public_projector,gurine_scheduler,gurine_document_extractor,
  gurine_identity_api,gurine_auditor,gurine_billing_gateway,
  gurine_economics_importer;
GRANT USAGE ON TYPE ops.payment_review_notification_materialize_v1,
  ops.payment_review_notification_materialize_receipt_v1
TO gurine_notification_worker;

CREATE FUNCTION ops.claim_r6e_donation_charge_job_v1(
  p ops.r6e_donation_charge_job_claim_v1
) RETURNS ops.r6e_donation_charge_job_claim_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_binding ops.payment_method_bindings%ROWTYPE;
  v_binding_id uuid;
  v_binding_digest char(64);
  v_attempt integer;
  v_fencing_token bigint;
  v_token uuid:=gen_random_uuid();
  v_expires timestamptz;
  v_digest char(64);
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF p IS NULL OR NULLIF(btrim((p).worker_id),'') IS NULL
     OR length((p).worker_id)>200
     OR (p).lease_seconds NOT BETWEEN 10 AND 600 THEN
    RAISE EXCEPTION 'R6E_DONATION_JOB_CLAIM_INVALID' USING ERRCODE='22023';
  END IF;
  SELECT job.* INTO v_job
  FROM ops.jobs AS job
  WHERE job.job_type='DONATION_CHARGE'
    AND job.queue='billing-gateway' AND job.status='QUEUED'
    AND job.run_after<=clock_timestamp()
    AND COALESCE((SELECT control.state FROM ops.queue_controls AS control
      WHERE control.queue_name=job.queue),'RUNNING')='RUNNING'
  ORDER BY job.priority,job.created_at,job.id
  LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN
    RETURN (
      'NONE',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
    )
      ::ops.r6e_donation_charge_job_claim_receipt_v1;
  END IF;
  IF jsonb_typeof(v_job.payload) IS DISTINCT FROM 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_job.payload))<>13
     OR NOT v_job.payload ?& ARRAY[
       'schemaVersion','donationScheduleId','donationScheduleVersion',
       'donationScheduleDigest','paymentMethodBindingId',
       'paymentMethodBindingDigest','offerVersionId','offerDigest','tierId',
       'consentReceiptDigest','logicalChargeId',
       'chargeIdempotencyKeySha256','scheduledFor'
     ] OR v_job.payload->>'schemaVersion'<>'donation-charge-job.v1' THEN
    RAISE EXCEPTION 'R6E_DONATION_JOB_PAYLOAD_INVALID' USING ERRCODE='23514';
  END IF;
  BEGIN
    v_binding_id:=(v_job.payload->>'paymentMethodBindingId')::uuid;
    v_binding_digest:=
      (v_job.payload->>'paymentMethodBindingDigest')::char(64);
  EXCEPTION
    WHEN invalid_text_representation OR string_data_right_truncation THEN
      RAISE EXCEPTION 'R6E_DONATION_JOB_PAYLOAD_INVALID'
        USING ERRCODE='23514';
  END;
  IF v_binding_id IS NULL OR v_binding_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_DONATION_JOB_PAYLOAD_INVALID' USING ERRCODE='23514';
  END IF;
  SELECT binding.* INTO v_binding
  FROM ops.payment_method_bindings AS binding
  WHERE binding.id=v_binding_id
    AND binding.record_digest=v_binding_digest
    AND binding.binding_state='ACTIVE'
    AND NOT EXISTS (
      SELECT 1 FROM ops.payment_method_bindings AS successor
      WHERE successor.supersedes_binding_id=binding.id
    )
  FOR SHARE OF binding;
  IF NOT FOUND
     OR v_binding.schedule_id::text IS DISTINCT FROM
       v_job.payload->>'donationScheduleId'
     OR v_binding.schedule_version::text IS DISTINCT FROM
       v_job.payload->>'donationScheduleVersion'
     OR btrim(v_binding.schedule_digest) IS DISTINCT FROM
       v_job.payload->>'donationScheduleDigest'
     OR v_binding.offer_version_id::text IS DISTINCT FROM
       v_job.payload->>'offerVersionId'
     OR btrim(v_binding.offer_digest) IS DISTINCT FROM
       v_job.payload->>'offerDigest'
     OR v_binding.tier_id::text IS DISTINCT FROM v_job.payload->>'tierId'
     OR btrim(v_binding.consent_receipt_digest) IS DISTINCT FROM
       v_job.payload->>'consentReceiptDigest'
     OR to_char(
       v_binding.first_charge_at AT TIME ZONE 'UTC',
       'YYYY-MM-DD"T"HH24:MI:SS"Z"'
     ) IS DISTINCT FROM v_job.payload->>'scheduledFor' THEN
    RAISE EXCEPTION 'R6E_DONATION_JOB_BINDING_INVALID' USING ERRCODE='23514';
  END IF;
  v_attempt:=v_job.attempt_count+1;
  v_expires:=clock_timestamp()+make_interval(secs=>(p).lease_seconds);
  UPDATE ops.jobs SET status='RUNNING',lease_owner=(p).worker_id,
    lease_token=v_token,lease_expires_at=v_expires,
    fencing_token=fencing_token+1,attempt_count=v_attempt,version=version+1
  WHERE id=v_job.id AND status='QUEUED'
  RETURNING fencing_token INTO v_fencing_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_DONATION_JOB_CLAIM_STALE' USING ERRCODE='40001';
  END IF;
  INSERT INTO ops.job_attempts(
    job_id,attempt,worker_id,fencing_token,started_at
  ) VALUES (
    v_job.id,v_attempt,(p).worker_id,v_fencing_token,clock_timestamp()
  );
  v_digest:=ops.r6e_payment_sha256_jsonb_v1(v_job.payload);
  RETURN (
    'CLAIMED',v_job.id,v_job.job_type,v_job.queue,v_job.payload,
    v_binding.provider,v_binding.mandate_amount::bigint,v_attempt,
    v_job.max_attempts,v_token,v_fencing_token,v_expires,v_digest
  )::ops.r6e_donation_charge_job_claim_receipt_v1;
END
$$;

CREATE FUNCTION ops.claim_r6e_donation_charge_v1(
  p ops.r6e_donation_charge_claim_v1
) RETURNS ops.r6e_donation_charge_claim_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_job_attempt ops.job_attempts%ROWTYPE;
  v_binding ops.payment_method_bindings%ROWTYPE;
  v_head ops.payment_charge_attempts%ROWTYPE;
  v_fact ops.donation_facts%ROWTYPE;
  v_task ops.tasks%ROWTYPE;
  v_attempt_id uuid:=gen_random_uuid();
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_job_digest char(64);
  v_lease_digest char(64);
  v_binding_id uuid;
  v_binding_digest char(64);
  v_logical_charge_id uuid;
  v_charge_idempotency_digest char(64);
  v_claim_digest char(64);
  v_record_digest char(64);
  v_accepted_completion_digest char(64);
  v_accepted_record_digest char(64);
  v_donation_event_id uuid;
  v_review_event_id uuid;
  v_audit_id uuid;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF p IS NULL OR (p).job_id IS NULL
     OR NULLIF(btrim((p).worker_id),'') IS NULL
     OR length((p).worker_id)>200 OR (p).job_lease_token IS NULL
     OR (p).job_fencing_token IS NULL OR (p).job_fencing_token<1
     OR (p).job_binding_digest !~ '^[0-9a-f]{64}$'
     OR (p).provider_idempotency_key_hmac !~ '^[0-9a-f]{64}$'
     OR (p).provider_idempotency_hmac_key_version
       !~ '^sha256:[0-9a-f]{16}$'
     OR (p).merchant_order_id_hmac !~ '^[0-9a-f]{64}$'
     OR (p).merchant_order_hmac_key_version
       !~ '^sha256:[0-9a-f]{16}$'
     OR (p).merchant_order_id_digest !~ '^[0-9a-f]{64}$'
     OR (p).expected_provider_payment_id_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_CLAIM_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_job FROM ops.jobs WHERE id=(p).job_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  SELECT * INTO v_job_attempt FROM ops.job_attempts
  WHERE job_id=v_job.id AND attempt=v_job.attempt_count FOR UPDATE;
  v_job_digest:=ops.r6e_payment_sha256_jsonb_v1(v_job.payload);
  v_lease_digest:=encode(extensions.digest(
    convert_to('gurine-job-lease-token.v1','UTF8')||decode('00','hex')
      ||uuid_send((p).job_lease_token),'sha256'
  ),'hex')::char(64);
  IF v_job.job_type IS DISTINCT FROM 'DONATION_CHARGE'
     OR v_job.queue IS DISTINCT FROM 'billing-gateway'
     OR v_job.status IS DISTINCT FROM 'RUNNING'
     OR v_job.lease_owner IS DISTINCT FROM (p).worker_id
     OR v_job.lease_token IS DISTINCT FROM (p).job_lease_token
     OR v_job.fencing_token IS DISTINCT FROM (p).job_fencing_token
     OR v_job.lease_expires_at IS NULL
     OR v_job.lease_expires_at<=clock_timestamp()
     OR v_job_digest IS DISTINCT FROM (p).job_binding_digest
     OR v_job_attempt.id IS NULL
     OR v_job_attempt.worker_id IS DISTINCT FROM (p).worker_id
     OR v_job_attempt.fencing_token IS DISTINCT FROM (p).job_fencing_token
     OR v_job_attempt.finished_at IS NOT NULL
     OR jsonb_typeof(v_job.payload) IS DISTINCT FROM 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_job.payload))<>13
     OR NOT v_job.payload ?& ARRAY[
       'schemaVersion','donationScheduleId','donationScheduleVersion',
       'donationScheduleDigest','paymentMethodBindingId',
       'paymentMethodBindingDigest','offerVersionId','offerDigest','tierId',
       'consentReceiptDigest','logicalChargeId',
       'chargeIdempotencyKeySha256','scheduledFor'
     ] THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_FENCE_INVALID'
      USING ERRCODE='55000';
  END IF;
  BEGIN
    v_binding_id:=(v_job.payload->>'paymentMethodBindingId')::uuid;
    v_binding_digest:=(v_job.payload->>'paymentMethodBindingDigest')::char(64);
    v_logical_charge_id:=(v_job.payload->>'logicalChargeId')::uuid;
    v_charge_idempotency_digest:=
      (v_job.payload->>'chargeIdempotencyKeySha256')::char(64);
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_PAYLOAD_INVALID'
      USING ERRCODE='23514';
  END;
  IF v_job.payload->>'schemaVersion'<>'donation-charge-job.v1'
     OR v_binding_id IS NULL OR v_binding_digest !~ '^[0-9a-f]{64}$'
     OR v_logical_charge_id IS NULL
     OR v_charge_idempotency_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_PAYLOAD_INVALID'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_binding FROM ops.payment_method_bindings
  WHERE id=v_binding_id AND record_digest=v_binding_digest
    AND binding_state='ACTIVE' FOR SHARE;
  IF NOT FOUND
     OR v_binding.schedule_id::text IS DISTINCT FROM
       v_job.payload->>'donationScheduleId'
     OR v_binding.schedule_version::text IS DISTINCT FROM
       v_job.payload->>'donationScheduleVersion'
     OR btrim(v_binding.schedule_digest) IS DISTINCT FROM
       v_job.payload->>'donationScheduleDigest'
     OR v_binding.offer_version_id::text IS DISTINCT FROM
       v_job.payload->>'offerVersionId'
     OR btrim(v_binding.offer_digest) IS DISTINCT FROM
       v_job.payload->>'offerDigest'
     OR v_binding.tier_id::text IS DISTINCT FROM v_job.payload->>'tierId'
     OR btrim(v_binding.consent_receipt_digest) IS DISTINCT FROM
       v_job.payload->>'consentReceiptDigest'
     OR v_binding.billing_key_secret_reference IS DISTINCT FROM
       'fixture://billing-key/'||v_binding.root_binding_id::text||'@v2' THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_BINDING_INVALID'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_head FROM ops.payment_charge_attempts
  WHERE job_id=v_job.id ORDER BY observation_version DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    IF v_head.job_binding_digest IS DISTINCT FROM (p).job_binding_digest
       OR v_head.logical_charge_id IS DISTINCT FROM v_logical_charge_id
       OR v_head.charge_idempotency_key_sha256 IS DISTINCT FROM
         v_charge_idempotency_digest
       OR v_head.provider_idempotency_key_hmac IS DISTINCT FROM
         (p).provider_idempotency_key_hmac
       OR v_head.provider_idempotency_hmac_key_version IS DISTINCT FROM
         (p).provider_idempotency_hmac_key_version
       OR v_head.merchant_order_id_hmac IS DISTINCT FROM
         (p).merchant_order_id_hmac
       OR v_head.merchant_order_hmac_key_version IS DISTINCT FROM
         (p).merchant_order_hmac_key_version
       OR v_head.merchant_order_id_digest IS DISTINCT FROM
         (p).merchant_order_id_digest
       OR v_head.expected_provider_payment_id_digest IS DISTINCT FROM
         (p).expected_provider_payment_id_digest THEN
      RETURN (
        'CONFLICT',v_head.root_attempt_id,v_head.record_digest,
        v_head.attempt_state,v_head.terminal_authority,
        v_head.producer_operation_id,v_head.provider,
        v_head.provider_idempotency_key_hmac,
        v_head.provider_idempotency_hmac_key_version,
        v_head.merchant_order_id_hmac,v_head.merchant_order_hmac_key_version,
        v_head.merchant_order_id_digest,
        v_head.expected_provider_payment_id_digest,v_head.amount::bigint,
        v_binding.credential_use_policy,v_binding.billing_key_secret_reference,
        v_binding.billing_key_hmac,v_binding.billing_key_hmac_key_version,
        v_binding.root_binding_id,v_binding.id,v_binding.record_digest,
        v_head.logical_charge_id,v_head.charge_idempotency_key_sha256,
        v_head.job_binding_digest,v_head.request_digest,NULL,
        NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
        NULL,NULL,NULL,NULL,NULL
      )::ops.r6e_donation_charge_claim_receipt_v1;
    END IF;
    IF v_head.attempt_state IN ('SUCCEEDED','FAILED','REFUNDED') THEN
      SELECT * INTO v_fact FROM ops.donation_facts
      WHERE payment_charge_attempt_id=v_head.root_attempt_id
        AND payment_charge_attempt_digest=v_head.record_digest
      ORDER BY revision DESC LIMIT 1;
      IF v_fact.id IS NOT NULL THEN
        SELECT event.id INTO v_donation_event_id FROM ops.outbox AS event
        WHERE event.aggregate_type='DonationFact'
          AND event.aggregate_id=v_fact.root_fact_id::text
          AND event.aggregate_version=v_fact.revision
          AND event.event_type='donation.fact_recorded.v1';
      END IF;
      SELECT * INTO v_task FROM ops.tasks
      WHERE task_type='PAYMENT_REVIEW'
        AND payment_review_source_kind='DONATION_PAYMENT_FAILURE'
        AND payment_review_source_receipt_id=v_head.root_attempt_id;
      IF v_task.id IS NOT NULL THEN
        SELECT event.id INTO v_review_event_id FROM ops.outbox AS event
        WHERE event.aggregate_type='payment_review_task'
          AND event.aggregate_id=v_task.id::text
          AND event.aggregate_version=v_task.version
          AND event.event_type='notification.payment_review_requested.v1';
      END IF;
    END IF;
    IF v_head.attempt_state='PROVIDER_ACCEPTED' THEN
      v_accepted_completion_digest:=ops.r6e_payment_sha256_jsonb_v1(
        jsonb_build_object(
          'schemaVersion','r6e-donation-charge-acceptance.v1',
          'attemptId',v_head.root_attempt_id,
          'claimDigest',btrim(v_head.request_digest),
          'providerPaymentIdDigest',
            btrim(v_head.provider_payment_id_digest),
          'transportRequestDigest',
            btrim(v_head.provider_transport_request_digest),
          'transportResponseDigest',
            btrim(v_head.provider_transport_response_digest),
          'fixtureAuthority',v_head.fixture_authority,
          'testPaymentOutcomeConfigDigest',
            btrim(v_head.test_payment_outcome_config_digest)
        )
      );
      v_accepted_record_digest:=ops.r6e_payment_sha256_jsonb_v1(
        jsonb_build_object(
          'schemaVersion','r6e-payment-charge-attempt.v1',
          'attemptState','PROVIDER_ACCEPTED',
          'completionRequestDigest',
            btrim(v_head.completion_request_digest),
          'observationId',v_head.id,
          'observationVersion',v_head.observation_version,
          'predecessorRecordDigest',
            btrim(v_head.predecessor_record_digest),
          'producerOperationId',v_head.producer_operation_id,
          'providerPaymentIdDigest',
            btrim(v_head.provider_payment_id_digest),
          'rootAttemptId',v_head.root_attempt_id
        )
      );
      IF v_head.observation_effect IS DISTINCT FROM 'PROVIDER_ACCEPTANCE'
         OR v_head.provider_payment_id_digest IS DISTINCT FROM
           v_head.expected_provider_payment_id_digest
         OR v_head.provider_transport_request_digest IS NULL
         OR v_head.provider_transport_response_digest IS NULL
         OR v_head.fixture_authority IS DISTINCT FROM 'TEST_FIXTURE'
         OR v_head.test_payment_outcome_config_digest IS NULL
         OR v_head.provider_observed_at IS NOT NULL
         OR v_head.completion_request_digest IS DISTINCT FROM
           v_accepted_completion_digest
         OR v_head.record_digest IS DISTINCT FROM
           v_accepted_record_digest THEN
        RAISE EXCEPTION 'R6E_DONATION_CHARGE_ACCEPTED_RECEIPT_CORRUPT'
          USING ERRCODE='55000';
      END IF;
    END IF;
    RETURN (
      CASE WHEN v_head.attempt_state IN ('SUCCEEDED','FAILED','REFUNDED')
        THEN 'REPLAY' ELSE 'IN_PROGRESS' END,
      v_head.root_attempt_id,v_head.record_digest,v_head.attempt_state,
      v_head.terminal_authority,v_head.producer_operation_id,v_head.provider,
      v_head.provider_idempotency_key_hmac,
      v_head.provider_idempotency_hmac_key_version,
      v_head.merchant_order_id_hmac,v_head.merchant_order_hmac_key_version,
      v_head.merchant_order_id_digest,
      v_head.expected_provider_payment_id_digest,v_head.amount::bigint,
      v_binding.credential_use_policy,v_binding.billing_key_secret_reference,
      v_binding.billing_key_hmac,v_binding.billing_key_hmac_key_version,
      v_binding.root_binding_id,v_binding.id,v_binding.record_digest,
      v_head.logical_charge_id,v_head.charge_idempotency_key_sha256,
      v_head.job_binding_digest,v_head.request_digest,
      CASE WHEN v_head.attempt_state IN ('SUCCEEDED','FAILED','REFUNDED')
        THEN v_head.record_digest ELSE NULL END,
      v_fact.id,v_fact.root_fact_id,v_fact.revision,v_fact.fact_effect,
      v_fact.fact_digest,v_fact.payment_charge_attempt_digest,
      v_fact.provider_fetch_digest,v_fact.recognized_at,v_donation_event_id,
      v_task.id,v_task.version,v_task.creation_digest,
      v_task.payment_review_source_kind,
      v_task.payment_review_source_receipt_id,
      v_task.payment_review_source_receipt_digest,v_task.created_at,
      v_task.payment_review_notification_intent_id,v_review_event_id,
      v_head.audit_event_id
    )::ops.r6e_donation_charge_claim_receipt_v1;
  END IF;
  IF EXISTS (
    SELECT 1 FROM ops.payment_method_bindings successor
    WHERE successor.supersedes_binding_id=v_binding.id
  ) THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_BINDING_NOT_CURRENT'
      USING ERRCODE='23514';
  END IF;
  v_claim_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-donation-charge-claim.v1',
    'attemptId',v_attempt_id,'expectedProviderPaymentIdDigest',
      btrim((p).expected_provider_payment_id_digest),
    'jobBindingDigest',btrim((p).job_binding_digest),
    'jobFencingToken',(p).job_fencing_token,'jobId',(p).job_id,
    'leaseTokenDigest',btrim(v_lease_digest),
    'merchantOrderIdDigest',btrim((p).merchant_order_id_digest),
    'providerIdempotencyKeyHmac',
      btrim((p).provider_idempotency_key_hmac)
  ));
  v_record_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-payment-charge-attempt.v1',
    'attemptId',v_attempt_id,'attemptState','REQUESTED',
    'claimDigest',btrim(v_claim_digest),
    'expectedProviderPaymentIdDigest',
      btrim((p).expected_provider_payment_id_digest),
    'jobBindingDigest',btrim((p).job_binding_digest),'jobId',(p).job_id,
    'logicalChargeId',v_logical_charge_id,'observationVersion',1,
    'producerOperationId','private.ExecuteDonationCharge'
  ));
  v_audit_id:=ops.append_audit_event(
    'payment-attempt:'||v_attempt_id::text,'SERVICE',current_user,NULL,
    'R6E_DONATION_CHARGE_REQUESTED','PaymentChargeAttempt',
    v_attempt_id::text,'payments.fixture','SUCCESS','charge requested',
    gen_random_uuid(),jsonb_build_object(
      'claimDigest',btrim(v_claim_digest),
      'jobBindingDigest',btrim((p).job_binding_digest),
      'producerOperationId','private.ExecuteDonationCharge',
      'recordDigest',btrim(v_record_digest)
    )
  );
  INSERT INTO ops.payment_charge_attempts(
    id,root_attempt_id,observation_version,observation_effect,
    supersedes_attempt_id,predecessor_record_digest,
    payment_method_binding_id,payment_method_binding_digest,job_id,worker_id,
    job_lease_token_digest,job_fencing_token,job_binding_digest,
    logical_charge_id,charge_idempotency_key_sha256,provider,
    provider_idempotency_key_hmac,provider_idempotency_hmac_key_version,
    merchant_order_id_hmac,merchant_order_hmac_key_version,
    merchant_order_id_digest,expected_provider_payment_id_digest,
    provider_locator_authority,provider_payment_id_digest,
    provider_observed_state,purpose,
    producer_operation_id,amount,currency,attempt_state,request_digest,
    provider_transport_request_digest,provider_transport_response_digest,
    provider_fetch_digest,fixture_authority,
    test_payment_outcome_config_digest,completion_request_digest,
    terminal_authority,local_failure_code,local_failure_evidence_digest,
    reconciliation_reason,reconciliation_evidence_digest,requested_at,
    provider_observed_at,terminal_at,audit_event_id,record_digest,recorded_at
  ) VALUES (
    v_attempt_id,v_attempt_id,1,'ORIGINAL',NULL,NULL,v_binding.id,
    v_binding.record_digest,v_job.id,(p).worker_id,v_lease_digest,
    (p).job_fencing_token,(p).job_binding_digest,v_logical_charge_id,
    v_charge_idempotency_digest,v_binding.provider,
    (p).provider_idempotency_key_hmac,
    (p).provider_idempotency_hmac_key_version,(p).merchant_order_id_hmac,
    (p).merchant_order_hmac_key_version,(p).merchant_order_id_digest,
    (p).expected_provider_payment_id_digest,
    'TEST_FIXTURE_DERIVED_EXPECTATION',NULL,NULL,'DONATION',
    'private.ExecuteDonationCharge',v_binding.mandate_amount,'KRW',
    'REQUESTED',v_claim_digest,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
    NULL,NULL,v_now,NULL,NULL,v_audit_id,v_record_digest,v_now
  );
  RETURN (
    'EXECUTE',v_attempt_id,v_record_digest,'REQUESTED',NULL,
    'private.ExecuteDonationCharge',v_binding.provider,
    (p).provider_idempotency_key_hmac,
    (p).provider_idempotency_hmac_key_version,(p).merchant_order_id_hmac,
    (p).merchant_order_hmac_key_version,(p).merchant_order_id_digest,
    (p).expected_provider_payment_id_digest,v_binding.mandate_amount::bigint,
    v_binding.credential_use_policy,v_binding.billing_key_secret_reference,
    v_binding.billing_key_hmac,v_binding.billing_key_hmac_key_version,
    v_binding.root_binding_id,v_binding.id,v_binding.record_digest,
    v_logical_charge_id,v_charge_idempotency_digest,(p).job_binding_digest,
    v_claim_digest,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
    NULL,NULL,NULL,NULL,NULL,NULL,NULL,v_audit_id
  )::ops.r6e_donation_charge_claim_receipt_v1;
END
$$;

CREATE FUNCTION ops.accept_r6e_donation_charge_v1(
  p ops.r6e_donation_charge_accept_v1
) RETURNS ops.r6e_payment_transition_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_head ops.payment_charge_attempts%ROWTYPE;
  v_id uuid:=gen_random_uuid();
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_expected char(64);
  v_digest char(64);
  v_audit_id uuid;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  v_expected:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-donation-charge-acceptance.v1',
    'attemptId',(p).attempt_id,'claimDigest',btrim((p).claim_digest),
    'providerPaymentIdDigest',btrim((p).provider_payment_id_digest),
    'transportRequestDigest',btrim((p).transport_request_digest),
    'transportResponseDigest',btrim((p).transport_response_digest),
    'fixtureAuthority',(p).fixture_authority,
    'testPaymentOutcomeConfigDigest',
      btrim((p).test_payment_outcome_config_digest)
  ));
  IF p IS NULL OR (p).attempt_id IS NULL
     OR (p).claim_digest !~ '^[0-9a-f]{64}$'
     OR (p).provider_payment_id_digest !~ '^[0-9a-f]{64}$'
     OR (p).transport_request_digest !~ '^[0-9a-f]{64}$'
     OR (p).transport_response_digest !~ '^[0-9a-f]{64}$'
     OR (p).fixture_authority<>'TEST_FIXTURE'
     OR (p).test_payment_outcome_config_digest !~ '^[0-9a-f]{64}$'
     OR (p).completion_request_digest IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_ACCEPTANCE_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_head FROM ops.payment_charge_attempts
  WHERE root_attempt_id=(p).attempt_id
  ORDER BY observation_version DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_ATTEMPT_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  IF v_head.request_digest IS DISTINCT FROM (p).claim_digest
     OR v_head.expected_provider_payment_id_digest IS DISTINCT FROM
       (p).provider_payment_id_digest THEN
    RETURN ('CONFLICT',v_head.root_attempt_id,v_head.id,v_head.attempt_state,
      v_head.record_digest,NULL)::ops.r6e_payment_transition_receipt_v1;
  END IF;
  IF v_head.attempt_state='PROVIDER_ACCEPTED' THEN
    RETURN (
      CASE WHEN v_head.completion_request_digest=(p).completion_request_digest
        AND v_head.provider_payment_id_digest=(p).provider_payment_id_digest
        AND v_head.provider_transport_request_digest=
          (p).transport_request_digest
        AND v_head.provider_transport_response_digest=
          (p).transport_response_digest
        AND v_head.fixture_authority=(p).fixture_authority
        AND v_head.test_payment_outcome_config_digest=
          (p).test_payment_outcome_config_digest
        AND v_head.provider_observed_at IS NULL
        THEN 'REPLAY' ELSE 'CONFLICT' END,
      v_head.root_attempt_id,v_head.id,v_head.attempt_state,
      v_head.record_digest,NULL
    )::ops.r6e_payment_transition_receipt_v1;
  END IF;
  IF v_head.attempt_state<>'REQUESTED' THEN
    RETURN ('CONFLICT',v_head.root_attempt_id,v_head.id,v_head.attempt_state,
      v_head.record_digest,NULL)::ops.r6e_payment_transition_receipt_v1;
  END IF;
  v_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-payment-charge-attempt.v1',
    'attemptState','PROVIDER_ACCEPTED',
    'completionRequestDigest',btrim((p).completion_request_digest),
    'observationId',v_id,
    'observationVersion',v_head.observation_version+1,
    'predecessorRecordDigest',btrim(v_head.record_digest),
    'producerOperationId','private.ExecuteDonationCharge',
    'providerPaymentIdDigest',btrim((p).provider_payment_id_digest),
    'rootAttemptId',v_head.root_attempt_id
  ));
  v_audit_id:=ops.append_audit_event(
    'payment-attempt:'||v_head.root_attempt_id::text,'SERVICE',current_user,
    NULL,'R6E_DONATION_CHARGE_PROVIDER_ACCEPTED','PaymentChargeAttempt',
    v_head.root_attempt_id::text,'payments.fixture','SUCCESS',
    'provider accepted; fetch still required',gen_random_uuid(),
    jsonb_build_object('recordDigest',btrim(v_digest),
      'producerOperationId','private.ExecuteDonationCharge')
  );
  INSERT INTO ops.payment_charge_attempts(
    id,root_attempt_id,observation_version,observation_effect,
    supersedes_attempt_id,predecessor_record_digest,
    payment_method_binding_id,payment_method_binding_digest,job_id,worker_id,
    job_lease_token_digest,job_fencing_token,job_binding_digest,
    logical_charge_id,charge_idempotency_key_sha256,provider,
    provider_idempotency_key_hmac,provider_idempotency_hmac_key_version,
    merchant_order_id_hmac,merchant_order_hmac_key_version,
    merchant_order_id_digest,expected_provider_payment_id_digest,
    provider_locator_authority,provider_payment_id_digest,
    provider_observed_state,purpose,
    producer_operation_id,amount,currency,attempt_state,request_digest,
    provider_transport_request_digest,provider_transport_response_digest,
    provider_fetch_digest,fixture_authority,
    test_payment_outcome_config_digest,completion_request_digest,
    terminal_authority,local_failure_code,local_failure_evidence_digest,
    reconciliation_reason,reconciliation_evidence_digest,requested_at,
    provider_observed_at,terminal_at,audit_event_id,record_digest,recorded_at
  ) SELECT
    v_id,root_attempt_id,observation_version+1,'PROVIDER_ACCEPTANCE',id,
    record_digest,payment_method_binding_id,payment_method_binding_digest,
    job_id,worker_id,job_lease_token_digest,job_fencing_token,
    job_binding_digest,logical_charge_id,charge_idempotency_key_sha256,
    provider,provider_idempotency_key_hmac,
    provider_idempotency_hmac_key_version,merchant_order_id_hmac,
    merchant_order_hmac_key_version,merchant_order_id_digest,
    expected_provider_payment_id_digest,provider_locator_authority,
    (p).provider_payment_id_digest,'PENDING',purpose,
    'private.ExecuteDonationCharge',
    amount,currency,'PROVIDER_ACCEPTED',request_digest,
    (p).transport_request_digest,(p).transport_response_digest,NULL,
    (p).fixture_authority,(p).test_payment_outcome_config_digest,
    (p).completion_request_digest,NULL,NULL,NULL,NULL,NULL,requested_at,
    NULL,NULL,v_audit_id,v_digest,v_now
  FROM ops.payment_charge_attempts WHERE id=v_head.id;
  RETURN ('APPLIED',v_head.root_attempt_id,v_id,'PROVIDER_ACCEPTED',v_digest,
    v_audit_id)::ops.r6e_payment_transition_receipt_v1;
END
$$;

CREATE FUNCTION ops.fail_r6e_donation_charge_v1(
  p ops.r6e_donation_charge_fail_v1
) RETURNS ops.r6e_donation_charge_terminal_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_head ops.payment_charge_attempts%ROWTYPE;
  v_job ops.jobs%ROWTYPE;
  v_id uuid:=gen_random_uuid();
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_expected char(64);
  v_digest char(64);
  v_audit_id uuid;
  v_changed bigint;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  v_expected:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-donation-charge-local-failure.v1',
    'attemptId',(p).attempt_id,'claimDigest',btrim((p).claim_digest),
    'safeCode',(p).safe_code,
    'failureEvidenceDigest',btrim((p).failure_evidence_digest)
  ));
  IF p IS NULL OR (p).attempt_id IS NULL
     OR (p).claim_digest !~ '^[0-9a-f]{64}$'
     OR (p).safe_code NOT IN (
       'INVALID_REQUEST','PAYMENT_RUNTIME_UNAVAILABLE','INTERNAL_ERROR'
     ) OR (p).failure_evidence_digest !~ '^[0-9a-f]{64}$'
     OR (p).completion_request_digest IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_LOCAL_FAILURE_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_head FROM ops.payment_charge_attempts
  WHERE root_attempt_id=(p).attempt_id
  ORDER BY observation_version DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_ATTEMPT_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  IF v_head.request_digest IS DISTINCT FROM (p).claim_digest THEN
    RETURN ('CONFLICT',v_head.root_attempt_id,v_head.attempt_state,
      v_head.terminal_authority,v_head.producer_operation_id,
      v_head.record_digest,NULL,NULL,'NONE',NULL,NULL,NULL,NULL,NULL,NULL,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)
      ::ops.r6e_donation_charge_terminal_receipt_v1;
  END IF;
  IF v_head.attempt_state='FAILED'
     AND v_head.terminal_authority='LOCAL_PRE_DISPATCH_REJECTION' THEN
    RETURN (
      CASE WHEN v_head.local_failure_code=(p).safe_code
        AND v_head.local_failure_evidence_digest=(p).failure_evidence_digest
        AND v_head.completion_request_digest=(p).completion_request_digest
        THEN 'REPLAY' ELSE 'CONFLICT' END,
      v_head.root_attempt_id,v_head.attempt_state,v_head.terminal_authority,
      v_head.producer_operation_id,v_head.record_digest,NULL,NULL,'NONE',
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
      NULL,NULL,NULL,NULL,v_head.audit_event_id
    )::ops.r6e_donation_charge_terminal_receipt_v1;
  END IF;
  IF v_head.attempt_state<>'REQUESTED' THEN
    RETURN ('CONFLICT',v_head.root_attempt_id,v_head.attempt_state,
      v_head.terminal_authority,v_head.producer_operation_id,
      v_head.record_digest,NULL,NULL,'NONE',NULL,NULL,NULL,NULL,NULL,NULL,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
      v_head.audit_event_id)
      ::ops.r6e_donation_charge_terminal_receipt_v1;
  END IF;
  SELECT * INTO v_job FROM ops.jobs WHERE id=v_head.job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING'
     OR v_job.lease_owner IS DISTINCT FROM v_head.worker_id
     OR v_job.fencing_token IS DISTINCT FROM v_head.job_fencing_token
     OR v_job.lease_expires_at IS NULL
     OR v_job.lease_expires_at<=clock_timestamp() THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_FENCE_INVALID'
      USING ERRCODE='55000';
  END IF;
  v_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-payment-charge-attempt.v1',
    'attemptState','FAILED',
    'completionRequestDigest',btrim((p).completion_request_digest),
    'localFailureCode',(p).safe_code,
    'localFailureEvidenceDigest',btrim((p).failure_evidence_digest),
    'observationId',v_id,
    'observationVersion',v_head.observation_version+1,
    'predecessorRecordDigest',btrim(v_head.record_digest),
    'producerOperationId','private.ExecuteDonationCharge',
    'rootAttemptId',v_head.root_attempt_id,
    'terminalAuthority','LOCAL_PRE_DISPATCH_REJECTION'
  ));
  v_audit_id:=ops.append_audit_event(
    'payment-attempt:'||v_head.root_attempt_id::text,'SERVICE',current_user,
    NULL,'R6E_DONATION_CHARGE_LOCALLY_REJECTED','PaymentChargeAttempt',
    v_head.root_attempt_id::text,'payments.fixture','FAILURE',(p).safe_code,
    gen_random_uuid(),jsonb_build_object(
      'failureEvidenceDigest',btrim((p).failure_evidence_digest),
      'recordDigest',btrim(v_digest),
      'terminalAuthority','LOCAL_PRE_DISPATCH_REJECTION')
  );
  INSERT INTO ops.payment_charge_attempts(
    id,root_attempt_id,observation_version,observation_effect,
    supersedes_attempt_id,predecessor_record_digest,
    payment_method_binding_id,payment_method_binding_digest,job_id,worker_id,
    job_lease_token_digest,job_fencing_token,job_binding_digest,
    logical_charge_id,charge_idempotency_key_sha256,provider,
    provider_idempotency_key_hmac,provider_idempotency_hmac_key_version,
    merchant_order_id_hmac,merchant_order_hmac_key_version,
    merchant_order_id_digest,expected_provider_payment_id_digest,
    provider_locator_authority,provider_payment_id_digest,purpose,
    producer_operation_id,amount,currency,attempt_state,request_digest,
    provider_transport_request_digest,provider_transport_response_digest,
    provider_fetch_digest,fixture_authority,
    test_payment_outcome_config_digest,completion_request_digest,
    terminal_authority,local_failure_code,local_failure_evidence_digest,
    reconciliation_reason,reconciliation_evidence_digest,requested_at,
    provider_observed_at,terminal_at,audit_event_id,record_digest,recorded_at
  ) SELECT
    v_id,root_attempt_id,observation_version+1,'LOCAL_REJECTION',id,
    record_digest,payment_method_binding_id,payment_method_binding_digest,
    job_id,worker_id,job_lease_token_digest,job_fencing_token,
    job_binding_digest,logical_charge_id,charge_idempotency_key_sha256,
    provider,provider_idempotency_key_hmac,
    provider_idempotency_hmac_key_version,merchant_order_id_hmac,
    merchant_order_hmac_key_version,merchant_order_id_digest,
    expected_provider_payment_id_digest,provider_locator_authority,NULL,
    purpose,'private.ExecuteDonationCharge',amount,currency,'FAILED',
    request_digest,NULL,NULL,NULL,NULL,NULL,(p).completion_request_digest,
    'LOCAL_PRE_DISPATCH_REJECTION',(p).safe_code,
    (p).failure_evidence_digest,NULL,NULL,requested_at,NULL,v_now,
    v_audit_id,v_digest,v_now
  FROM ops.payment_charge_attempts WHERE id=v_head.id;
  UPDATE ops.job_attempts SET finished_at=v_now,outcome='FAILED',
    error_code=(p).safe_code,error_detail=btrim((p).failure_evidence_digest),
    metrics=jsonb_build_object(
      'schemaVersion','r6e-donation-charge-job-terminal.v1',
      'attemptId',v_head.root_attempt_id,'attemptDigest',btrim(v_digest),
      'terminalAuthority','LOCAL_PRE_DISPATCH_REJECTION'
    )
  WHERE job_id=v_job.id AND attempt=v_job.attempt_count
    AND worker_id=v_job.lease_owner
    AND fencing_token=v_job.fencing_token AND finished_at IS NULL;
  GET DIAGNOSTICS v_changed=ROW_COUNT;
  IF v_changed<>1 THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_ATTEMPT_STALE'
      USING ERRCODE='40001';
  END IF;
  UPDATE ops.jobs SET status='FAILED',completed_at=v_now,
    lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
    version=version+1,last_error_code=(p).safe_code,
    last_error_detail=btrim((p).failure_evidence_digest),updated_at=v_now
  WHERE id=v_job.id AND status='RUNNING'
    AND lease_owner=v_job.lease_owner AND lease_token=v_job.lease_token
    AND fencing_token=v_job.fencing_token;
  GET DIAGNOSTICS v_changed=ROW_COUNT;
  IF v_changed<>1 THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_STALE' USING ERRCODE='40001';
  END IF;
  RETURN ('APPLIED',v_head.root_attempt_id,'FAILED',
    'LOCAL_PRE_DISPATCH_REJECTION','private.ExecuteDonationCharge',v_digest,
    NULL,NULL,'NONE',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
    NULL,NULL,NULL,NULL,NULL,NULL,NULL,v_audit_id)
    ::ops.r6e_donation_charge_terminal_receipt_v1;
END
$$;

CREATE FUNCTION ops.require_r6e_charge_reconciliation_v1(
  p ops.r6e_charge_reconciliation_v1
) RETURNS ops.r6e_payment_transition_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_head ops.payment_charge_attempts%ROWTYPE;
  v_job ops.jobs%ROWTYPE;
  v_id uuid:=gen_random_uuid();
  v_now timestamptz:=date_trunc('second',clock_timestamp());
  v_digest char(64);
  v_audit_id uuid;
  v_changed bigint;
BEGIN
  IF session_user<>'gurine_billing_gateway'
     OR current_user<>'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_BILLING_GATEWAY_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF p IS NULL OR (p).attempt_id IS NULL
     OR (p).claim_digest !~ '^[0-9a-f]{64}$'
     OR (p).reason NOT IN (
       'CHARGE_OUTCOME_UNKNOWN','FETCH_UNAVAILABLE','PROVIDER_PENDING',
       'PARTIAL_REFUND_AMOUNT_UNAVAILABLE'
     ) OR (p).evidence_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'R6E_CHARGE_RECONCILIATION_INVALID'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_head FROM ops.payment_charge_attempts
  WHERE root_attempt_id=(p).attempt_id
  ORDER BY observation_version DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_PAYMENT_ATTEMPT_NOT_FOUND' USING ERRCODE='P0002';
  END IF;
  IF v_head.request_digest IS DISTINCT FROM (p).claim_digest THEN
    RETURN ('CONFLICT',v_head.root_attempt_id,v_head.id,v_head.attempt_state,
      v_head.record_digest,NULL)::ops.r6e_payment_transition_receipt_v1;
  END IF;
  IF v_head.attempt_state='RECONCILIATION_REQUIRED' THEN
    RETURN (
      CASE WHEN v_head.reconciliation_reason=(p).reason
        AND v_head.reconciliation_evidence_digest=(p).evidence_digest
        THEN 'REPLAY' ELSE 'CONFLICT' END,
      v_head.root_attempt_id,v_head.id,v_head.attempt_state,
      v_head.record_digest,NULL
    )::ops.r6e_payment_transition_receipt_v1;
  END IF;
  IF v_head.attempt_state NOT IN ('REQUESTED','PROVIDER_ACCEPTED') THEN
    RETURN ('CONFLICT',v_head.root_attempt_id,v_head.id,v_head.attempt_state,
      v_head.record_digest,NULL)::ops.r6e_payment_transition_receipt_v1;
  END IF;
  SELECT * INTO v_job FROM ops.jobs WHERE id=v_head.job_id FOR UPDATE;
  IF NOT FOUND OR v_job.status<>'RUNNING'
     OR v_job.lease_owner IS DISTINCT FROM v_head.worker_id
     OR v_job.fencing_token IS DISTINCT FROM v_head.job_fencing_token THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_FENCE_INVALID'
      USING ERRCODE='55000';
  END IF;
  v_digest:=ops.r6e_payment_sha256_jsonb_v1(jsonb_build_object(
    'schemaVersion','r6e-payment-charge-attempt.v1',
    'attemptState','RECONCILIATION_REQUIRED',
    'evidenceDigest',btrim((p).evidence_digest),'observationId',v_id,
    'observationVersion',v_head.observation_version+1,
    'predecessorRecordDigest',btrim(v_head.record_digest),
    'producerOperationId','private.ExecuteDonationCharge',
    'reason',(p).reason,'rootAttemptId',v_head.root_attempt_id
  ));
  v_audit_id:=ops.append_audit_event(
    'payment-attempt:'||v_head.root_attempt_id::text,'SERVICE',current_user,
    NULL,'R6E_CHARGE_RECONCILIATION_REQUIRED','PaymentChargeAttempt',
    v_head.root_attempt_id::text,'payments.reconcile','FAILURE',(p).reason,
    gen_random_uuid(),jsonb_build_object(
      'evidenceDigest',btrim((p).evidence_digest),
      'recordDigest',btrim(v_digest),'donationMutationCount',0,
      'publicAccessMutationCount',0)
  );
  INSERT INTO ops.payment_charge_attempts(
    id,root_attempt_id,observation_version,observation_effect,
    supersedes_attempt_id,predecessor_record_digest,
    payment_method_binding_id,payment_method_binding_digest,job_id,worker_id,
    job_lease_token_digest,job_fencing_token,job_binding_digest,
    logical_charge_id,charge_idempotency_key_sha256,provider,
    provider_idempotency_key_hmac,provider_idempotency_hmac_key_version,
    merchant_order_id_hmac,merchant_order_hmac_key_version,
    merchant_order_id_digest,expected_provider_payment_id_digest,
    provider_locator_authority,provider_payment_id_digest,purpose,
    producer_operation_id,amount,currency,attempt_state,request_digest,
    provider_transport_request_digest,provider_transport_response_digest,
    provider_fetch_digest,fixture_authority,
    test_payment_outcome_config_digest,completion_request_digest,
    terminal_authority,local_failure_code,local_failure_evidence_digest,
    reconciliation_reason,reconciliation_evidence_digest,requested_at,
    provider_observed_at,terminal_at,audit_event_id,record_digest,recorded_at
  ) SELECT
    v_id,root_attempt_id,observation_version+1,'RECONCILIATION',id,
    record_digest,payment_method_binding_id,payment_method_binding_digest,
    job_id,worker_id,job_lease_token_digest,job_fencing_token,
    job_binding_digest,logical_charge_id,charge_idempotency_key_sha256,
    provider,provider_idempotency_key_hmac,
    provider_idempotency_hmac_key_version,merchant_order_id_hmac,
    merchant_order_hmac_key_version,merchant_order_id_digest,
    expected_provider_payment_id_digest,provider_locator_authority,NULL,
    purpose,'private.ExecuteDonationCharge',amount,currency,
    'RECONCILIATION_REQUIRED',request_digest,NULL,NULL,NULL,NULL,NULL,NULL,
    NULL,NULL,NULL,(p).reason,(p).evidence_digest,requested_at,NULL,NULL,
    v_audit_id,v_digest,v_now
  FROM ops.payment_charge_attempts WHERE id=v_head.id;
  UPDATE ops.job_attempts SET finished_at=v_now,outcome='FAILED',
    error_code='RECONCILIATION_REQUIRED',
    error_detail=btrim((p).evidence_digest),metrics=jsonb_build_object(
      'schemaVersion','r6e-donation-charge-job-terminal.v1',
      'attemptId',v_head.root_attempt_id,'attemptDigest',btrim(v_digest),
      'reconciliationReason',(p).reason
    ) WHERE job_id=v_job.id AND attempt=v_job.attempt_count
      AND worker_id=v_job.lease_owner AND fencing_token=v_job.fencing_token
      AND finished_at IS NULL;
  GET DIAGNOSTICS v_changed=ROW_COUNT;
  IF v_changed<>1 THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_ATTEMPT_STALE'
      USING ERRCODE='40001';
  END IF;
  UPDATE ops.jobs SET status='FAILED',completed_at=v_now,
    lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
    version=version+1,last_error_code='RECONCILIATION_REQUIRED',
    last_error_detail=btrim((p).evidence_digest),updated_at=v_now
  WHERE id=v_job.id AND status='RUNNING'
    AND lease_owner=v_job.lease_owner AND lease_token=v_job.lease_token
    AND fencing_token=v_job.fencing_token;
  GET DIAGNOSTICS v_changed=ROW_COUNT;
  IF v_changed<>1 THEN
    RAISE EXCEPTION 'R6E_DONATION_CHARGE_JOB_STALE' USING ERRCODE='40001';
  END IF;
  RETURN ('APPLIED',v_head.root_attempt_id,v_id,'RECONCILIATION_REQUIRED',
    v_digest,v_audit_id)::ops.r6e_payment_transition_receipt_v1;
END
$$;

-- R6E_PAYMENT_SCHEDULER_STATUS_FINAL
-- Fail closed: the authority contracts name the scheduler owner but do not
-- define monthly anchor/clamp, missed-period catch-up, or post-failure next-
-- period eligibility.  No callable enqueue or standalone recovery reader is
-- installed until those high-impact payment scheduling decisions are frozen.

-- Donation funding candidates are a private TEST_FIXTURE-only staging input.
-- The projection worker supplies the leased delivery fence, but every event,
-- payment and fact authority is re-read and locked inside this owner boundary.
CREATE TYPE ops.donation_funding_candidate_projection_v1 AS (
  job_id uuid,
  job_lease_token uuid,
  job_fencing_token bigint,
  worker_id text,
  event_id uuid,
  aggregate_root_fact_id uuid,
  aggregate_version bigint,
  donation_fact_id uuid,
  donation_fact_digest char(64),
  charge_attempt_id uuid,
  charge_attempt_digest char(64),
  provider_fetch_digest char(64),
  donation_occurred_at timestamptz,
  event_occurred_at timestamptz
);
CREATE TYPE ops.donation_funding_candidate_receipt_v1 AS (
  job_id uuid,
  job_fencing_token bigint,
  event_id uuid,
  aggregate_root_fact_id uuid,
  aggregate_version bigint,
  donation_fact_id uuid,
  donation_fact_digest char(64),
  candidate_header_digest char(64),
  candidate_entry_digest char(64),
  inbox_receipt_digest char(64),
  job_receipt_digest char(64),
  audit_event_digest char(64),
  receipt_digest char(64),
  completed_at timestamptz
);
REVOKE ALL ON TYPE ops.donation_funding_candidate_projection_v1,
  ops.donation_funding_candidate_receipt_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.donation_funding_candidate_projection_v1,
  ops.donation_funding_candidate_receipt_v1
TO gurine_public_projector;

-- The 0029 relation made these IDs mandatory without attaching the intended
-- immutable authorities.  Existing invalid provenance aborts this migration.
ALTER TABLE ops.funding_concentration_snapshots
  ADD CONSTRAINT funding_snapshot_audit_event_exact_fk
    FOREIGN KEY (audit_event_id) REFERENCES ops.audit_events(id)
      ON DELETE RESTRICT,
  ADD CONSTRAINT funding_snapshot_outbox_event_exact_fk
    FOREIGN KEY (outbox_id) REFERENCES ops.outbox(id)
      ON DELETE RESTRICT;
CREATE UNIQUE INDEX funding_snapshot_header_outbox_once_uq
  ON ops.funding_concentration_snapshots(outbox_id)
  WHERE row_kind='SNAPSHOT_HEADER';

CREATE FUNCTION ops.project_donation_fact_candidate_v1(
  p_input ops.donation_funding_candidate_projection_v1
) RETURNS ops.donation_funding_candidate_receipt_v1
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
SET timezone='UTC'
AS $project_donation_fact_candidate_v1$
DECLARE
  v_now timestamptz;
  v_job ops.jobs%ROWTYPE;
  v_attempt ops.job_attempts%ROWTYPE;
  v_inbox ops.inbox%ROWTYPE;
  v_outbox ops.outbox%ROWTYPE;
  v_fact ops.donation_facts%ROWTYPE;
  v_charge ops.payment_charge_attempts%ROWTYPE;
  v_binding ops.payment_method_bindings%ROWTYPE;
  v_predecessor ops.donation_facts%ROWTYPE;
  v_prior_event ops.outbox%ROWTYPE;
  v_prior_inbox ops.inbox%ROWTYPE;
  v_prior_header ops.funding_concentration_snapshots%ROWTYPE;
  v_header ops.funding_concentration_snapshots%ROWTYPE;
  v_entry ops.funding_concentration_snapshots%ROWTYPE;
  v_helper_audit ops.audit_events%ROWTYPE;
  v_helper_outbox ops.outbox%ROWTYPE;
  v_audit ops.audit_events%ROWTYPE;
  v_import ops.funding_snapshot_import_v1;
  v_import_entry ops.funding_snapshot_entry_input_v1;
  v_import_receipt ops.funding_snapshot_import_receipt_v1;
  v_existing ops.donation_funding_candidate_receipt_v1;
  v_result ops.donation_funding_candidate_receipt_v1;
  v_stored jsonb;
  v_prior_result jsonb;
  v_expected_result jsonb;
  v_expected_job_payload jsonb;
  v_expected_outbox_payload jsonb;
  v_batch_id uuid;
  v_group_id uuid;
  v_fiscal_year integer;
  v_snapshot_version bigint;
  v_policy_version constant text :=
    'R6E_DONATION_CANDIDATE_TEST_FIXTURE_V1';
  v_policy_digest char(64);
  v_fx_digest char(64);
  v_group_key_digest char(64);
  v_group_digest char(64);
  v_group_evidence_digest char(64);
  v_source_set_digest char(64);
  v_entry_source_set_digest char(64);
  v_independent_review_digest char(64);
  v_entry_set_digest char(64);
  v_entry_digest char(64);
  v_snapshot_digest char(64);
  v_outbox_digest char(64);
  v_helper_outbox_digest char(64);
  v_helper_receipt_digest char(64);
  v_helper_response_digest char(64);
  v_worker_digest char(64);
  v_lease_digest char(64);
  v_input_digest char(64);
  v_job_receipt_digest char(64);
  v_inbox_receipt_digest char(64);
  v_audit_event_id uuid;
  v_audit_event_digest char(64);
  v_receipt_digest char(64);
  v_recognized_amount numeric(24,6);
  v_binding_amount numeric(24,6);
  v_numerator numeric(24,6);
  v_job_occurred_at timestamptz;
  v_donation_event_occurred_at timestamptz;
  v_expected_job_occurred_at text;
  v_group_hex text;
  v_count bigint;
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_public_projector'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_ROLE_REQUIRED'
      USING ERRCODE='42501';
  END IF;
  IF current_setting('transaction_isolation') IS DISTINCT FROM 'serializable' THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_SERIALIZABLE_REQUIRED'
      USING ERRCODE='25001';
  END IF;
  IF p_input IS NULL
     OR (p_input).job_id IS NULL
     OR (p_input).job_lease_token IS NULL
     OR (p_input).job_fencing_token IS NULL
     OR (p_input).job_fencing_token<1
     OR (p_input).worker_id IS NULL
     OR length(btrim((p_input).worker_id)) NOT BETWEEN 1 AND 200
     OR (p_input).event_id IS NULL
     OR (p_input).aggregate_root_fact_id IS NULL
     OR (p_input).aggregate_version IS NULL
     OR (p_input).aggregate_version<1
     OR (p_input).donation_fact_id IS NULL
     OR btrim((p_input).donation_fact_digest::text)
       !~ '^[0-9a-f]{64}$'
     OR (p_input).charge_attempt_id IS NULL
     OR btrim((p_input).charge_attempt_digest::text)
       !~ '^[0-9a-f]{64}$'
     OR btrim((p_input).provider_fetch_digest::text)
       !~ '^[0-9a-f]{64}$'
     OR (p_input).donation_occurred_at IS NULL
     OR (p_input).event_occurred_at IS NULL
     OR (p_input).event_occurred_at<(p_input).donation_occurred_at THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_INPUT_INVALID'
      USING ERRCODE='22023';
  END IF;

  SELECT job.* INTO v_job
  FROM ops.jobs AS job
  WHERE job.id=(p_input).job_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_JOB_MISSING'
      USING ERRCODE='23514';
  END IF;
  SELECT attempt.* INTO v_attempt
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id=v_job.id
    AND attempt.attempt=v_job.attempt_count
  FOR UPDATE;
  IF NOT FOUND
     OR v_attempt.worker_id IS DISTINCT FROM (p_input).worker_id
     OR v_attempt.fencing_token IS DISTINCT FROM
       (p_input).job_fencing_token THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_ATTEMPT_FENCE_INVALID'
      USING ERRCODE='40001';
  END IF;
  SELECT inbox.* INTO v_inbox
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='funding-projector'
    AND inbox.event_id=(p_input).event_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_INBOX_MISSING'
      USING ERRCODE='23514';
  END IF;
  SELECT event.* INTO v_outbox
  FROM ops.outbox AS event
  WHERE event.id=(p_input).event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_EVENT_MISSING'
      USING ERRCODE='23514';
  END IF;
  BEGIN
    v_job_occurred_at:=(v_job.payload->>'occurredAt')::timestamptz;
    v_donation_event_occurred_at:=
      (v_outbox.payload->>'occurredAt')::timestamptz;
  EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
    RAISE EXCEPTION 'R6E_DONATION_EVENT_REPLAY_CONFLICT'
      USING ERRCODE='23514';
  END;
  v_expected_outbox_payload:=jsonb_build_object(
    'donationFactId',(p_input).donation_fact_id,
    'donationFactDigest',btrim((p_input).donation_fact_digest::text),
    'chargeAttemptId',(p_input).charge_attempt_id,
    'chargeAttemptDigest',btrim((p_input).charge_attempt_digest::text),
    'providerFetchDigest',btrim((p_input).provider_fetch_digest::text),
    'occurredAt',(p_input).donation_occurred_at
  );
  -- The scheduler serializes SQLx OffsetDateTime with time::Rfc3339.  Its UTC
  -- form uses Z and removes fractional trailing zeroes; jsonb timestamptz
  -- rendering uses +00:00 and therefore cannot prove the stored job payload.
  v_expected_job_occurred_at:=CASE
    WHEN date_trunc('second',(p_input).event_occurred_at)=
      (p_input).event_occurred_at THEN
      to_char((p_input).event_occurred_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ELSE rtrim(to_char(
      (p_input).event_occurred_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US'
    ),'0')||'Z'
  END;
  v_expected_job_payload:=jsonb_build_object(
    'consumerId','funding-projector','eventId',(p_input).event_id,
    'eventType','donation.fact_recorded.v1','aggregateType','DonationFact',
    'aggregateId',(p_input).aggregate_root_fact_id,
    'aggregateVersion',(p_input).aggregate_version,
    'occurredAt',v_expected_job_occurred_at,
    'payload',v_expected_outbox_payload
  );

  IF v_job.job_type IS DISTINCT FROM 'EVENT_DELIVERY'
     OR v_job.queue IS DISTINCT FROM 'projection-worker'
     OR v_job.dedupe_key IS DISTINCT FROM
       'event:'||(p_input).event_id::text||':funding-projector'
     OR jsonb_typeof(v_job.payload) IS DISTINCT FROM 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_job.payload))<>8
     OR NOT v_job.payload ?& ARRAY[
       'consumerId','eventId','eventType','aggregateType','aggregateId',
       'aggregateVersion','occurredAt','payload'
     ]
     OR v_job.payload IS DISTINCT FROM v_expected_job_payload
     OR v_job.payload->>'consumerId' IS DISTINCT FROM 'funding-projector'
     OR v_job.payload->>'eventId' IS DISTINCT FROM (p_input).event_id::text
     OR v_job.payload->>'eventType'
       IS DISTINCT FROM 'donation.fact_recorded.v1'
     OR v_job.payload->>'aggregateType' IS DISTINCT FROM 'DonationFact'
     OR v_job.payload->>'aggregateId'
       IS DISTINCT FROM (p_input).aggregate_root_fact_id::text
     OR v_job.payload->>'aggregateVersion'
       IS DISTINCT FROM (p_input).aggregate_version::text
     OR v_job_occurred_at IS DISTINCT FROM (p_input).event_occurred_at
     OR v_job.payload->'payload' IS DISTINCT FROM v_outbox.payload
     OR v_outbox.aggregate_type IS DISTINCT FROM 'DonationFact'
     OR v_outbox.aggregate_id
       IS DISTINCT FROM (p_input).aggregate_root_fact_id::text
     OR v_outbox.aggregate_version
       IS DISTINCT FROM (p_input).aggregate_version
     OR v_outbox.event_type IS DISTINCT FROM 'donation.fact_recorded.v1'
     OR v_outbox.occurred_at IS DISTINCT FROM (p_input).event_occurred_at
     OR jsonb_typeof(v_outbox.payload) IS DISTINCT FROM 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_outbox.payload))<>6
     OR NOT v_outbox.payload ?& ARRAY[
       'donationFactId','donationFactDigest','chargeAttemptId',
       'chargeAttemptDigest','providerFetchDigest','occurredAt'
     ]
     OR v_outbox.payload IS DISTINCT FROM v_expected_outbox_payload
     OR v_outbox.payload->>'donationFactId'
       IS DISTINCT FROM (p_input).donation_fact_id::text
     OR v_outbox.payload->>'donationFactDigest'
       IS DISTINCT FROM btrim((p_input).donation_fact_digest::text)
     OR v_outbox.payload->>'chargeAttemptId'
       IS DISTINCT FROM (p_input).charge_attempt_id::text
     OR v_outbox.payload->>'chargeAttemptDigest'
       IS DISTINCT FROM btrim((p_input).charge_attempt_digest::text)
     OR v_outbox.payload->>'providerFetchDigest'
       IS DISTINCT FROM btrim((p_input).provider_fetch_digest::text)
     OR v_donation_event_occurred_at
       IS DISTINCT FROM (p_input).donation_occurred_at
     OR NOT EXISTS (
       SELECT 1 FROM ops.event_types AS event_type
       WHERE event_type.event_type='donation.fact_recorded.v1'
         AND event_type.active AND event_type.schema_version=1
         AND event_type.payload_schema_uri=
           'payloads/donation_fact_recorded_v1.schema.json'
     ) THEN
    RAISE EXCEPTION 'R6E_DONATION_EVENT_REPLAY_CONFLICT'
      USING ERRCODE='23514';
  END IF;

  SELECT fact.* INTO v_fact
  FROM ops.donation_facts AS fact
  WHERE fact.id=(p_input).donation_fact_id
    AND fact.fact_digest=(p_input).donation_fact_digest;
  SELECT attempt.* INTO v_charge
  FROM ops.payment_charge_attempts AS attempt
  WHERE attempt.root_attempt_id=(p_input).charge_attempt_id
    AND attempt.record_digest=(p_input).charge_attempt_digest;
  IF v_fact.id IS NULL OR v_charge.id IS NULL THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_SOURCE_BINDING_MISSING'
      USING ERRCODE='23514';
  END IF;
  SELECT binding.* INTO v_binding
  FROM ops.payment_method_bindings AS binding
  WHERE binding.id=v_charge.payment_method_binding_id
    AND binding.record_digest=v_charge.payment_method_binding_digest;
  IF NOT FOUND
     OR v_binding.environment IS DISTINCT FROM 'TEST'
     OR v_binding.fixture_authority IS DISTINCT FROM
       'TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY'
     OR v_binding.binding_state IS DISTINCT FROM 'ACTIVE'
     OR v_binding.billing_key_secret_reference IS DISTINCT FROM
       'fixture://billing-key/'||v_binding.root_binding_id::text||'@v2'
     OR v_binding.provider IS DISTINCT FROM v_charge.provider
     OR v_binding.deployment_id IS DISTINCT FROM v_fact.deployment_id
     OR v_binding.donor_hmac IS DISTINCT FROM v_fact.donor_hmac
     OR v_binding.donor_group_hmac IS DISTINCT FROM v_fact.donor_group_hmac
     OR v_binding.donor_hmac_key_version
       IS DISTINCT FROM v_fact.donor_hmac_key_version
     OR v_binding.donor_hmac_key_version
       IS DISTINCT FROM v_fact.donor_group_hmac_key_version
     OR v_charge.root_attempt_id
       IS DISTINCT FROM v_fact.payment_charge_attempt_id
     OR v_charge.record_digest
       IS DISTINCT FROM v_fact.payment_charge_attempt_digest
     OR v_charge.provider_fetch_digest
       IS DISTINCT FROM (p_input).provider_fetch_digest
     OR v_fact.provider_fetch_digest
       IS DISTINCT FROM (p_input).provider_fetch_digest
     OR v_charge.amount IS DISTINCT FROM v_fact.amount
     OR v_charge.currency IS DISTINCT FROM v_fact.currency
     OR v_fact.root_fact_id
       IS DISTINCT FROM (p_input).aggregate_root_fact_id
     OR v_fact.revision IS DISTINCT FROM (p_input).aggregate_version
     OR v_fact.recognized_at
       IS DISTINCT FROM (p_input).donation_occurred_at
     OR v_fact.funding_source_kind IS DISTINCT FROM 'DONATION'
     OR v_fact.investigation_exemption
     OR v_fact.access_entitlement_granted
     OR (v_fact.fact_effect IN ('ORIGINAL','REPLACEMENT')
       AND v_charge.attempt_state IS DISTINCT FROM 'SUCCEEDED')
     OR (v_fact.fact_effect='REVERSAL'
       AND v_charge.attempt_state IS DISTINCT FROM 'REFUNDED')
     OR v_charge.fixture_authority IS DISTINCT FROM 'TEST_FIXTURE'
     OR v_charge.test_payment_outcome_config_digest IS NULL
     OR v_charge.provider_fetch_digest IS NULL
     OR v_charge.terminal_authority IS DISTINCT FROM
       'PROVIDER_FETCH_CONFIRMED'
     OR v_charge.terminal_at IS NULL
     OR v_charge.provider_observed_at IS NULL
     OR v_charge.terminal_at>v_fact.recognized_at THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_TEST_AUTHORITY_INVALID'
      USING ERRCODE='42501';
  END IF;

  v_outbox_digest:=ops.r6d_outbox_envelope_digest_v1(v_outbox.id);
  v_worker_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-worker-identity-binding.v1',
      'workerId',(p_input).worker_id
    )),'sha256'),'hex');
  v_lease_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-job-lease-token-binding.v1',
      'jobLeaseToken',(p_input).job_lease_token
    )),'sha256'),'hex');
  v_input_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-donation-funding-candidate-input.v1',
      'jobId',(p_input).job_id,
      'jobLeaseTokenDigest',v_lease_digest,
      'jobFencingToken',(p_input).job_fencing_token,
      'workerIdentityDigest',v_worker_digest,
      'eventId',(p_input).event_id,
      'aggregateType','DonationFact',
      'aggregateRootFactId',(p_input).aggregate_root_fact_id,
      'aggregateVersion',(p_input).aggregate_version,
      'eventType','donation.fact_recorded.v1',
      'donationFactId',(p_input).donation_fact_id,
      'donationFactDigest',btrim((p_input).donation_fact_digest::text),
      'chargeAttemptId',(p_input).charge_attempt_id,
      'chargeAttemptDigest',btrim((p_input).charge_attempt_digest::text),
      'providerFetchDigest',btrim((p_input).provider_fetch_digest::text),
      'donationOccurredAt',(p_input).donation_occurred_at,
      'eventOccurredAt',(p_input).event_occurred_at,
      'outboxEnvelopeDigest',v_outbox_digest
    )),'sha256'),'hex');
  v_policy_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-donation-funding-candidate-policy.v1',
      'authority','TEST_FIXTURE','environment','TEST',
      'productionReadiness',false,'publicTruth',false,
      'publicationAuthority','NONE',
      'denominatorState','UNKNOWN',
      'denominatorUnknownReason','MISSING',
      'classificationAuthority','MISSING_REVIEW',
      'fundingSourceKind','DONATION',
      'investigationExemptionAllowed',false,
      'accessEntitlementAllowed',false
    )),'sha256'),'hex');
  v_fx_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-donation-candidate-fx.v1',
      'authority','TEST_FIXTURE','kind','IDENTITY_NO_CONVERSION',
      'currency',v_fact.currency
    )),'sha256'),'hex');
  v_group_key_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-donation-counterparty-group-key.v1',
      'authority','TEST_FIXTURE',
      'donorGroupHmac',v_fact.donor_group_hmac,
      'donorGroupHmacKeyVersion',v_fact.donor_group_hmac_key_version
    )),'sha256'),'hex');
  v_group_hex:=substring(v_group_key_digest::text,1,12)||'4'||
    substring(v_group_key_digest::text,14,3)||'8'||
    substring(v_group_key_digest::text,18,15);
  v_group_id:=(substring(v_group_hex,1,8)||'-'||
    substring(v_group_hex,9,4)||'-'||substring(v_group_hex,13,4)||'-'||
    substring(v_group_hex,17,4)||'-'||substring(v_group_hex,21,12))::uuid;
  v_group_evidence_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-donation-grouping-evidence.v1',
      'authority','TEST_FIXTURE',
      'counterpartyGroupId',v_group_id,
      'counterpartyGroupKeyDigest',v_group_key_digest,
      'donationFactId',v_fact.id,
      'donationFactDigest',v_fact.fact_digest,
      'groupingState','RESOLVED'
    )),'sha256'),'hex');
  v_group_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_COUNTERPARTY_GROUP_V1',
      'schemaVersion',1,
      'counterpartyGroupId',v_group_id,
      'groupingState','RESOLVED'::ops.funding_grouping_state,
      'groupingDisputeReason',NULL::ops.funding_grouping_dispute_reason,
      'groupingEvidenceDigest',v_group_evidence_digest,
      'memberSupplierIds','{}'::uuid[],
      'memberSupplierIdentityDigests','{}'::char(64)[]
    )),'sha256'),'hex');
  v_independent_review_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'domain','GURINE_FUNDING_INDEPENDENT_REVIEW_REQUIREMENT_V1',
      'schemaVersion',1,
      'counterpartyGroupDigest',v_group_digest,
      'concentrationBand','UNKNOWN'::editorial.funding_concentration_band,
      'concentrationUnknownReason',
        'DENOMINATOR_UNKNOWN'::ops.funding_concentration_unknown_reason,
      'investigatedSubjectRelated',false,
      'relatedParty',false,
      'relatedCaseIds','{}'::uuid[]
    )),'sha256'),'hex');
  v_entry_source_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'domain','GURINE_FUNDING_ENTRY_SOURCE_SET_V1',
      'schemaVersion',1,
      'recognizedRevenueFactIds','{}'::uuid[],
      'recognizedRevenueFactDigests','{}'::char(64)[],
      'recognizedRevenueFactAmounts','{}'::numeric(24,6)[],
      'bindingContractPeriodIds','{}'::uuid[],
      'bindingContractPeriodDigests','{}'::char(64)[],
      'bindingContractPeriodAmounts','{}'::numeric(24,6)[],
      'externalFundingSourceReceiptIds',ARRAY[v_fact.id]::uuid[],
      'externalFundingSourceReceiptDigests',
        ARRAY[v_fact.fact_digest]::char(64)[],
      'externalFundingSourceSignatureDigests',
        ARRAY[v_fact.provider_fetch_digest]::char(64)[],
      'externalFundingSourceKinds',
        ARRAY['DONATION'::ops.funding_source_kind],
      'externalFundingSourceFactEffects',ARRAY[v_fact.fact_effect]::text[],
      'externalFundingAmountBases',ARRAY[v_fact.amount_basis],
      'externalFundingSourceAmounts',ARRAY[v_fact.amount]::numeric(24,6)[]
    )),'sha256'),'hex');
  v_source_set_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_SOURCE_SET_V1',
      'schemaVersion',1,
      'sources',jsonb_build_array(jsonb_build_object(
        'ordinal',1,'entrySourceSetDigest',v_entry_source_set_digest
      ))
    )),'sha256'),'hex');
  IF v_fact.fact_effect='REVERSAL' THEN
    v_recognized_amount:=0;
    v_binding_amount:=0;
  ELSIF v_fact.amount_basis='RECOGNIZED' THEN
    v_recognized_amount:=v_fact.amount;
    v_binding_amount:=0;
  ELSE
    v_recognized_amount:=0;
    v_binding_amount:=v_fact.amount;
  END IF;
  v_numerator:=v_recognized_amount+v_binding_amount;
  v_fiscal_year:=extract(year FROM
    v_fact.recognized_at AT TIME ZONE 'UTC')::integer;
  v_entry_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_ENTRY_V1',
      'schemaVersion',1,'ordinal',1,
      'counterpartyGroupId',v_group_id,
      'counterpartyGroupDigest',v_group_digest,
      'groupingState','RESOLVED'::ops.funding_grouping_state,
      'groupingDisputeReason',NULL::ops.funding_grouping_dispute_reason,
      'groupingEvidenceDigest',v_group_evidence_digest,
      'memberSupplierIds','{}'::uuid[],
      'memberSupplierIdentityDigests','{}'::char(64)[],
      'fundingSourceKind','DONATION'::ops.funding_source_kind,
      'recognizedRevenue',v_recognized_amount,
      'bindingCommittedRevenue',v_binding_amount,
      'numerator',v_numerator,'concentrationShare',NULL::numeric,
      'concentrationBand','UNKNOWN'::editorial.funding_concentration_band,
      'concentrationUnknownReason',
        'DENOMINATOR_UNKNOWN'::ops.funding_concentration_unknown_reason,
      'governmentRelated',false,'politicalPartyRelated',false,
      'procurementSupplierRelated',false,
      'investigatedSubjectRelated',false,'relatedParty',false,
      'relatedCaseIds','{}'::uuid[],
      'entrySourceSetDigest',v_entry_source_set_digest,
      'independentReviewRequirementDigest',v_independent_review_digest
    )),'sha256'),'hex');
  v_entry_set_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_ENTRY_SET_V1',
      'schemaVersion',1,
      'entries',jsonb_build_array(jsonb_build_object(
        'ordinal',1,'entryDigest',v_entry_digest
      ))
    )),'sha256'),'hex');

  -- Exact replay revalidates the immutable source and every stored redacted
  -- receipt.  It does not require the historical fact to remain the head.
  IF v_inbox.processed_at IS NOT NULL THEN
    BEGIN
      v_stored:=v_inbox.result::jsonb;
      IF jsonb_typeof(v_stored) IS DISTINCT FROM 'object'
         OR (SELECT count(*) FROM jsonb_object_keys(v_stored))<>14
         OR NOT v_stored ?& ARRAY[
           'jobId','jobFencingToken','eventId','aggregateRootFactId',
           'aggregateVersion','donationFactId','donationFactDigest',
           'candidateHeaderDigest','candidateEntryDigest',
           'inboxReceiptDigest','jobReceiptDigest','auditEventDigest',
           'receiptDigest','completedAt'
         ] THEN
        RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_REPLAY_RECEIPT_INVALID'
          USING ERRCODE='23514';
      END IF;
      v_existing:=ROW(
        (v_stored->>'jobId')::uuid,
        (v_stored->>'jobFencingToken')::bigint,
        (v_stored->>'eventId')::uuid,
        (v_stored->>'aggregateRootFactId')::uuid,
        (v_stored->>'aggregateVersion')::bigint,
        (v_stored->>'donationFactId')::uuid,
        (v_stored->>'donationFactDigest')::char(64),
        (v_stored->>'candidateHeaderDigest')::char(64),
        (v_stored->>'candidateEntryDigest')::char(64),
        (v_stored->>'inboxReceiptDigest')::char(64),
        (v_stored->>'jobReceiptDigest')::char(64),
        (v_stored->>'auditEventDigest')::char(64),
        (v_stored->>'receiptDigest')::char(64),
        (v_stored->>'completedAt')::timestamptz
      )::ops.donation_funding_candidate_receipt_v1;
    EXCEPTION WHEN invalid_text_representation OR invalid_datetime_format
      OR datetime_field_overflow OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_REPLAY_RECEIPT_INVALID'
        USING ERRCODE='23514';
    END;
    IF v_existing.job_id IS DISTINCT FROM (p_input).job_id
       OR v_existing.job_fencing_token IS DISTINCT FROM
         (p_input).job_fencing_token
       OR v_existing.event_id IS DISTINCT FROM (p_input).event_id
       OR v_existing.aggregate_root_fact_id IS DISTINCT FROM
         (p_input).aggregate_root_fact_id
       OR v_existing.aggregate_version IS DISTINCT FROM
         (p_input).aggregate_version
       OR v_existing.donation_fact_id IS DISTINCT FROM
         (p_input).donation_fact_id
       OR v_existing.donation_fact_digest IS DISTINCT FROM
         (p_input).donation_fact_digest
       OR v_existing.completed_at IS DISTINCT FROM v_inbox.processed_at
       OR v_job.status IS DISTINCT FROM 'SUCCEEDED'
       OR v_job.completed_at IS DISTINCT FROM v_existing.completed_at
       OR v_job.fencing_token IS DISTINCT FROM
         (p_input).job_fencing_token
       OR v_job.lease_owner IS NOT NULL
       OR v_job.lease_token IS NOT NULL
       OR v_job.lease_expires_at IS NOT NULL
       OR v_job.last_error_code IS NOT NULL
       OR v_job.last_error_detail IS NOT NULL
       OR v_attempt.finished_at IS DISTINCT FROM v_existing.completed_at
       OR v_attempt.outcome IS DISTINCT FROM 'SUCCEEDED'
       OR v_attempt.error_code IS NOT NULL
       OR v_attempt.error_detail IS NOT NULL THEN
      RAISE EXCEPTION 'R6E_DONATION_EVENT_REPLAY_CONFLICT'
        USING ERRCODE='23514';
    END IF;
    SELECT audit.* INTO v_audit
    FROM ops.audit_events AS audit
    WHERE audit.event_hash=v_existing.audit_event_digest
      AND audit.actor_type='SERVICE'
      AND audit.actor_id='funding-projector'
      AND audit.session_id IS NULL
      AND audit.action='DONATION_FUNDING_CANDIDATE_PROJECTED'
      AND audit.object_type='DonationFundingCandidate'
      AND audit.object_id=(p_input).event_id::text
      AND audit.capability IS NULL
      AND audit.outcome='SUCCESS'
      AND audit.reason IS NULL
      AND audit.request_id=(p_input).job_id;
    SELECT header.* INTO v_header
    FROM ops.funding_concentration_snapshots AS header
    WHERE header.row_kind='SNAPSHOT_HEADER'
      AND header.snapshot_digest=v_existing.candidate_header_digest;
    SELECT helper_audit.* INTO v_helper_audit
    FROM ops.audit_events AS helper_audit
    WHERE helper_audit.id=v_header.audit_event_id
      AND helper_audit.actor_type='SERVICE'
      AND helper_audit.actor_id='funding-projector'
      AND helper_audit.session_id IS NULL
      AND helper_audit.action='DONATION_FUNDING_CANDIDATE_PROJECTED'
      AND helper_audit.object_type='FundingConcentrationSnapshot'
      AND helper_audit.object_id=v_header.snapshot_batch_id::text
      AND helper_audit.capability IS NULL
      AND helper_audit.outcome='SUCCESS'
      AND helper_audit.reason='AUTHENTICATED_DONATION_FACT';
    SELECT helper_outbox.* INTO v_helper_outbox
    FROM ops.outbox AS helper_outbox
    WHERE helper_outbox.id=v_header.outbox_id
      AND helper_outbox.aggregate_type='FundingConcentrationSnapshot'
      AND helper_outbox.aggregate_id=v_header.snapshot_batch_id::text
      AND helper_outbox.aggregate_version=v_header.snapshot_version
      AND helper_outbox.event_type='governance.funding_snapshot_created.v1';
    SELECT entry.* INTO v_entry
    FROM ops.funding_concentration_snapshots AS entry
    WHERE entry.row_kind='COUNTERPARTY_ENTRY'
      AND entry.header_id=v_header.id
      AND entry.entry_digest=v_existing.candidate_entry_digest;
    IF v_audit.id IS NULL OR v_header.id IS NULL OR v_entry.id IS NULL
       OR v_helper_audit.id IS NULL OR v_helper_outbox.id IS NULL
       OR v_header.snapshot_batch_id IS DISTINCT FROM v_entry.snapshot_batch_id
       OR v_header.snapshot_version IS DISTINCT FROM v_entry.snapshot_version
       OR v_header.fiscal_year IS DISTINCT FROM v_fiscal_year
       OR v_header.as_of IS DISTINCT FROM v_fact.recognized_at
       OR v_header.reporting_currency IS DISTINCT FROM v_fact.currency
       OR v_header.funding_policy_version IS DISTINCT FROM v_policy_version
       OR v_header.funding_policy_digest IS DISTINCT FROM v_policy_digest
       OR v_header.fx_snapshot_digest IS DISTINCT FROM v_fx_digest
       OR v_header.denominator_state IS DISTINCT FROM 'UNKNOWN'
       OR v_header.denominator_unknown_reason IS DISTINCT FROM 'MISSING'
       OR v_header.entry_count IS DISTINCT FROM 1
       OR v_header.source_set_digest IS DISTINCT FROM v_source_set_digest
       OR v_entry.ordinal IS DISTINCT FROM 1
       OR v_entry.header_id IS DISTINCT FROM v_header.id
       OR v_entry.counterparty_group_id IS DISTINCT FROM v_group_id
       OR v_entry.counterparty_group_digest IS DISTINCT FROM v_group_digest
       OR v_entry.grouping_state IS DISTINCT FROM 'RESOLVED'
       OR v_entry.grouping_dispute_reason IS NOT NULL
       OR v_entry.grouping_evidence_digest
         IS DISTINCT FROM v_group_evidence_digest
       OR v_entry.member_supplier_ids IS DISTINCT FROM '{}'::uuid[]
       OR v_entry.member_supplier_identity_digests
         IS DISTINCT FROM '{}'::char(64)[]
       OR v_entry.funding_source_kind IS DISTINCT FROM 'DONATION'
       OR v_entry.recognized_revenue IS DISTINCT FROM v_recognized_amount
       OR v_entry.binding_committed_revenue IS DISTINCT FROM v_binding_amount
       OR v_entry.numerator IS DISTINCT FROM v_numerator
       OR v_entry.concentration_share IS NOT NULL
       OR v_entry.concentration_band IS DISTINCT FROM 'UNKNOWN'
       OR v_entry.concentration_unknown_reason
         IS DISTINCT FROM 'DENOMINATOR_UNKNOWN'
       OR v_entry.government_related OR v_entry.political_party_related
       OR v_entry.procurement_supplier_related
       OR v_entry.investigated_subject_related OR v_entry.related_party
       OR v_entry.related_case_ids IS DISTINCT FROM '{}'::uuid[]
       OR v_entry.recognized_revenue_fact_ids IS DISTINCT FROM '{}'::uuid[]
       OR v_entry.recognized_revenue_fact_digests
         IS DISTINCT FROM '{}'::char(64)[]
       OR v_entry.recognized_revenue_fact_amounts
         IS DISTINCT FROM '{}'::numeric(24,6)[]
       OR v_entry.binding_contract_period_ids IS DISTINCT FROM '{}'::uuid[]
       OR v_entry.binding_contract_period_digests
         IS DISTINCT FROM '{}'::char(64)[]
       OR v_entry.binding_contract_period_amounts
         IS DISTINCT FROM '{}'::numeric(24,6)[]
       OR v_entry.external_funding_source_receipt_ids
         IS DISTINCT FROM ARRAY[v_fact.id]::uuid[]
       OR v_entry.external_funding_source_receipt_digests
         IS DISTINCT FROM ARRAY[v_fact.fact_digest]::char(64)[]
       OR v_entry.external_funding_source_signature_digests
         IS DISTINCT FROM ARRAY[v_fact.provider_fetch_digest]::char(64)[]
       OR v_entry.external_funding_source_kinds
         IS DISTINCT FROM ARRAY['DONATION'::ops.funding_source_kind]
       OR v_entry.external_funding_amount_bases
         IS DISTINCT FROM ARRAY[v_fact.amount_basis]
       OR v_entry.external_funding_source_amounts
         IS DISTINCT FROM ARRAY[v_fact.amount]::numeric(24,6)[]
       OR v_entry.entry_source_set_digest
         IS DISTINCT FROM v_entry_source_set_digest
       OR v_entry.independent_review_requirement_digest
         IS DISTINCT FROM v_independent_review_digest THEN
      RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_REPLAY_PROOF_INVALID'
        USING ERRCODE='23514';
    END IF;
    v_entry_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'domain','GURINE_FUNDING_SNAPSHOT_ENTRY_V1',
        'schemaVersion',1,'ordinal',1,
        'counterpartyGroupId',v_group_id,
        'counterpartyGroupDigest',v_group_digest,
        'groupingState','RESOLVED'::ops.funding_grouping_state,
        'groupingDisputeReason',NULL::ops.funding_grouping_dispute_reason,
        'groupingEvidenceDigest',v_group_evidence_digest,
        'memberSupplierIds','{}'::uuid[],
        'memberSupplierIdentityDigests','{}'::char(64)[],
        'fundingSourceKind','DONATION'::ops.funding_source_kind,
        'recognizedRevenue',v_recognized_amount,
        'bindingCommittedRevenue',v_binding_amount,'numerator',v_numerator,
        'concentrationShare',NULL::numeric,
        'concentrationBand','UNKNOWN'::editorial.funding_concentration_band,
        'concentrationUnknownReason',
          'DENOMINATOR_UNKNOWN'::ops.funding_concentration_unknown_reason,
        'governmentRelated',false,'politicalPartyRelated',false,
        'procurementSupplierRelated',false,
        'investigatedSubjectRelated',false,'relatedParty',false,
        'relatedCaseIds','{}'::uuid[],
        'entrySourceSetDigest',v_entry_source_set_digest,
        'independentReviewRequirementDigest',v_independent_review_digest
      )),'sha256'),'hex');
    v_entry_set_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'domain','GURINE_FUNDING_SNAPSHOT_ENTRY_SET_V1',
        'schemaVersion',1,
        'entries',jsonb_build_array(jsonb_build_object(
          'ordinal',1,'entryDigest',v_entry_digest
        ))
      )),'sha256'),'hex');
    v_snapshot_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'domain','GURINE_FUNDING_SNAPSHOT_V1','schemaVersion',1,
        'snapshotBatchId',v_header.snapshot_batch_id,
        'snapshotVersion',v_header.snapshot_version,
        'fiscalYear',v_fiscal_year,'asOf',v_fact.recognized_at,
        'reportingCurrency',v_fact.currency,
        'priorHeaderId',v_header.prior_header_id,
        'priorSnapshotDigest',v_header.prior_snapshot_digest,
        'fundingPolicyVersion',v_policy_version,
        'fundingPolicyDigest',v_policy_digest,'fxSnapshotDigest',v_fx_digest,
        'denominatorAmount',NULL::numeric,
        'denominatorState','UNKNOWN'::ops.funding_denominator_state,
        'denominatorUnknownReason','MISSING'::ops.funding_denominator_unknown_reason,
        'denominatorApprovalDigest',NULL::char(64),
        'denominatorApproverSetDigest',NULL::char(64),
        'denominatorApprovedAt',NULL::timestamptz,
        'denominatorApprovalExpiresAt',NULL::timestamptz,
        'entryCount',1,'entrySetDigest',v_entry_set_digest,
        'sourceSetDigest',v_source_set_digest
      )),'sha256'),'hex');
    v_helper_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'domain','GURINE_FUNDING_SNAPSHOT_IMPORT_RECEIPT_V1',
        'schemaVersion',1,'receiptId',v_header.id,
        'snapshotHeaderId',v_header.id,
        'snapshotBatchId',v_header.snapshot_batch_id,
        'snapshotVersion',v_header.snapshot_version,
        'snapshotDigest',v_snapshot_digest,'entryCount',1,
        'entrySetDigest',v_entry_set_digest,
        'committedAt',v_header.imported_at
      )),'sha256'),'hex');
    v_helper_outbox_digest:=ops.r6d_outbox_envelope_digest_v1(
      v_helper_outbox.id
    );
    IF v_header.entry_set_digest IS DISTINCT FROM v_entry_set_digest
       OR v_header.snapshot_digest IS DISTINCT FROM v_snapshot_digest
       OR v_header.import_receipt_digest
         IS DISTINCT FROM v_helper_receipt_digest
       OR v_entry.entry_digest IS DISTINCT FROM v_entry_digest
       OR v_helper_audit.details IS DISTINCT FROM jsonb_build_object(
         'snapshotVersion',v_header.snapshot_version,
         'snapshotDigest',v_snapshot_digest,
         'entryCount',1,'entrySetDigest',v_entry_set_digest,
         'sourceSetDigest',v_source_set_digest,
         'authority','TEST_FIXTURE','publicationAuthority','NONE'
       )
       OR v_helper_outbox.payload IS DISTINCT FROM jsonb_build_object(
         'snapshotBatchId',v_header.snapshot_batch_id,
         'fiscalYear',v_fiscal_year,'asOf',v_fact.recognized_at,
         'reportingCurrency',v_fact.currency,
         'fxSnapshotDigest',v_fx_digest,'denominatorState','UNKNOWN',
         'denominatorUnknownReason','MISSING','denominator',NULL,
         'denominatorApprovalDigest',NULL,
         'entrySetDigest',v_entry_set_digest,
         'snapshotDigest',v_snapshot_digest,
         'receiptDigest',v_helper_receipt_digest
       )
       OR v_helper_outbox.occurred_at IS DISTINCT FROM v_header.imported_at
       OR v_helper_outbox_digest IS NULL
       OR v_audit.details IS DISTINCT FROM jsonb_build_object(
         'schemaVersion','r6e-donation-funding-candidate-audit.v1',
         'jobId',(p_input).job_id,
         'jobFencingToken',(p_input).job_fencing_token,
         'eventId',(p_input).event_id,
         'aggregateRootFactId',(p_input).aggregate_root_fact_id,
         'aggregateVersion',(p_input).aggregate_version,
         'donationFactId',(p_input).donation_fact_id,
         'donationFactDigest',(p_input).donation_fact_digest,
         'candidateHeaderDigest',v_snapshot_digest,
         'candidateEntryDigest',v_entry_digest,
         'inputBindingDigest',v_input_digest,
         'sourceOutboxEnvelopeDigest',v_outbox_digest,
         'helperSnapshotReceiptDigest',v_helper_receipt_digest,
         'helperAuditEventDigest',v_helper_audit.event_hash,
         'helperOutboxEnvelopeDigest',v_helper_outbox_digest,
         'authority','TEST_FIXTURE','publicationAuthority','NONE',
         'publicMutationCount',0,'outboxEventCount',1
       ) THEN
      RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_REPLAY_HELPER_INVALID'
        USING ERRCODE='23514';
    END IF;
    v_job_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'schemaVersion','r6e-donation-candidate-job-terminal.v1',
        'jobId',v_job.id,'jobType','EVENT_DELIVERY',
        'queue','projection-worker','jobVersion',v_job.version,
        'attempt',v_job.attempt_count,'attemptId',v_attempt.id,
        'attemptStartedAt',v_attempt.started_at,'status','SUCCEEDED',
        'jobFencingToken',(p_input).job_fencing_token,
        'leaseTokenDigest',v_lease_digest,
        'workerIdentityDigest',v_worker_digest,
        'eventId',(p_input).event_id,'inputBindingDigest',v_input_digest,
        'completedAt',v_existing.completed_at
      )),'sha256'),'hex');
    v_inbox_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'schemaVersion','r6e-donation-candidate-inbox-terminal.v1',
        'consumer','funding-projector','eventId',(p_input).event_id,
        'receivedAt',v_inbox.received_at,
        'processedAt',v_existing.completed_at,
        'inputBindingDigest',v_input_digest,
        'candidateHeaderDigest',v_snapshot_digest,
        'candidateEntryDigest',v_entry_digest,
        'jobReceiptDigest',v_job_receipt_digest
      )),'sha256'),'hex');
    v_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'schemaVersion','donation-funding-candidate-receipt.v1',
        'jobId',(p_input).job_id,
        'jobFencingToken',(p_input).job_fencing_token,
        'eventId',(p_input).event_id,
        'aggregateRootFactId',(p_input).aggregate_root_fact_id,
        'aggregateVersion',(p_input).aggregate_version,
        'donationFactId',(p_input).donation_fact_id,
        'donationFactDigest',(p_input).donation_fact_digest,
        'candidateHeaderDigest',v_snapshot_digest,
        'candidateEntryDigest',v_entry_digest,
        'inboxReceiptDigest',v_inbox_receipt_digest,
        'jobReceiptDigest',v_job_receipt_digest,
        'auditEventDigest',v_audit.event_hash,
        'completedAt',v_existing.completed_at
      )),'sha256'),'hex');
    IF v_entry.entry_digest IS DISTINCT FROM v_entry_digest
       OR v_header.entry_set_digest IS DISTINCT FROM v_entry_set_digest
       OR v_header.snapshot_digest IS DISTINCT FROM v_snapshot_digest
       OR v_existing.candidate_entry_digest IS DISTINCT FROM v_entry_digest
       OR v_existing.candidate_header_digest IS DISTINCT FROM v_snapshot_digest
       OR v_existing.job_receipt_digest IS DISTINCT FROM v_job_receipt_digest
       OR v_existing.inbox_receipt_digest IS DISTINCT FROM v_inbox_receipt_digest
       OR v_existing.audit_event_digest IS DISTINCT FROM v_audit.event_hash
       OR v_existing.receipt_digest IS DISTINCT FROM v_receipt_digest
       OR v_attempt.metrics IS DISTINCT FROM jsonb_build_object(
         'schemaVersion','r6e-donation-candidate-job-metrics.v1',
         'eventId',(p_input).event_id,
         'candidateHeaderDigest',v_snapshot_digest,
         'candidateEntryDigest',v_entry_digest,
         'receiptDigest',v_receipt_digest
       ) THEN
      RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_REPLAY_DIGEST_INVALID'
        USING ERRCODE='23514';
    END IF;
    v_expected_result:=jsonb_build_object(
      'jobId',v_existing.job_id,
      'jobFencingToken',v_existing.job_fencing_token,
      'eventId',v_existing.event_id,
      'aggregateRootFactId',v_existing.aggregate_root_fact_id,
      'aggregateVersion',v_existing.aggregate_version,
      'donationFactId',v_existing.donation_fact_id,
      'donationFactDigest',v_existing.donation_fact_digest,
      'candidateHeaderDigest',v_existing.candidate_header_digest,
      'candidateEntryDigest',v_existing.candidate_entry_digest,
      'inboxReceiptDigest',v_existing.inbox_receipt_digest,
      'jobReceiptDigest',v_existing.job_receipt_digest,
      'auditEventDigest',v_existing.audit_event_digest,
      'receiptDigest',v_existing.receipt_digest,
      'completedAt',v_existing.completed_at
    );
    IF v_stored IS DISTINCT FROM v_expected_result THEN
      RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_REPLAY_RECEIPT_INVALID'
        USING ERRCODE='23514';
    END IF;
    RETURN v_existing;
  END IF;

  v_now:=clock_timestamp();
  IF v_inbox.result IS DISTINCT FROM 'DISPATCHED:'||(p_input).job_id::text
     OR v_job.status IS DISTINCT FROM 'RUNNING'
     OR v_job.lease_owner IS DISTINCT FROM (p_input).worker_id
     OR v_job.lease_token IS DISTINCT FROM (p_input).job_lease_token
     OR v_job.fencing_token IS DISTINCT FROM (p_input).job_fencing_token
     OR v_job.lease_expires_at IS NULL OR v_job.lease_expires_at<=v_now
     OR v_attempt.finished_at IS NOT NULL OR v_attempt.outcome IS NOT NULL
     OR v_attempt.error_code IS NOT NULL OR v_attempt.error_detail IS NOT NULL
     OR EXISTS (
       SELECT 1 FROM ops.donation_facts AS successor
       WHERE successor.supersedes_fact_id=v_fact.id
     )
     OR EXISTS (
       SELECT 1 FROM ops.payment_charge_attempts AS successor
       WHERE successor.supersedes_attempt_id=v_charge.id
     ) THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_STALE_OR_REGRESSION'
      USING ERRCODE='40001';
  END IF;

  IF v_fact.revision=1 THEN
    IF v_fact.fact_effect IS DISTINCT FROM 'ORIGINAL'
       OR v_fact.supersedes_fact_id IS NOT NULL
       OR v_fact.predecessor_fact_digest IS NOT NULL THEN
      RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_CHAIN_INVALID'
        USING ERRCODE='23514';
    END IF;
  ELSE
    SELECT predecessor.* INTO v_predecessor
    FROM ops.donation_facts AS predecessor
    WHERE predecessor.id=v_fact.supersedes_fact_id
      AND predecessor.fact_digest=v_fact.predecessor_fact_digest
      AND predecessor.root_fact_id=v_fact.root_fact_id
      AND predecessor.revision=v_fact.revision-1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_CHAIN_GAP'
        USING ERRCODE='40001';
    END IF;
    SELECT event.* INTO v_prior_event
    FROM ops.outbox AS event
    WHERE event.aggregate_type='DonationFact'
      AND event.aggregate_id=v_fact.root_fact_id::text
      AND event.aggregate_version=v_fact.revision-1
      AND event.event_type='donation.fact_recorded.v1'
      AND event.payload->>'donationFactId'=v_predecessor.id::text
      AND event.payload->>'donationFactDigest'=
        btrim(v_predecessor.fact_digest::text);
    SELECT inbox.* INTO v_prior_inbox
    FROM ops.inbox AS inbox
    WHERE inbox.consumer='funding-projector'
      AND inbox.event_id=v_prior_event.id
      AND inbox.processed_at IS NOT NULL
    FOR SHARE;
    BEGIN
      v_prior_result:=v_prior_inbox.result::jsonb;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_ORDERING_GAP'
        USING ERRCODE='40001';
    END;
    IF v_prior_event.id IS NULL OR v_prior_inbox.event_id IS NULL
       OR jsonb_typeof(v_prior_result) IS DISTINCT FROM 'object'
       OR v_prior_result->>'aggregateRootFactId'
         IS DISTINCT FROM v_fact.root_fact_id::text
       OR v_prior_result->>'aggregateVersion'
         IS DISTINCT FROM (v_fact.revision-1)::text
       OR COALESCE(v_prior_result->>'receiptDigest','')
         !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_ORDERING_GAP'
        USING ERRCODE='40001';
    END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'FUNDING_SNAPSHOT_FISCAL_YEAR:'||v_fiscal_year::text,0
  ));
  SELECT header.* INTO v_prior_header
  FROM ops.funding_concentration_snapshots AS header
  WHERE header.row_kind='SNAPSHOT_HEADER'
    AND header.fiscal_year=v_fiscal_year
  ORDER BY header.snapshot_version DESC,header.id DESC
  LIMIT 1;
  IF v_prior_header.id IS NOT NULL
     AND (v_prior_header.funding_policy_version
       IS DISTINCT FROM v_policy_version
       OR v_prior_header.funding_policy_digest
         IS DISTINCT FROM v_policy_digest) THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_POLICY_CHAIN_CONFLICT'
      USING ERRCODE='42501';
  END IF;
  v_snapshot_version:=COALESCE(v_prior_header.snapshot_version,0)+1;
  v_batch_id:=gen_random_uuid();
  v_snapshot_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_V1','schemaVersion',1,
      'snapshotBatchId',v_batch_id,'snapshotVersion',v_snapshot_version,
      'fiscalYear',v_fiscal_year,'asOf',v_fact.recognized_at,
      'reportingCurrency',v_fact.currency,
      'priorHeaderId',v_prior_header.id,
      'priorSnapshotDigest',v_prior_header.snapshot_digest,
      'fundingPolicyVersion',v_policy_version,
      'fundingPolicyDigest',v_policy_digest,'fxSnapshotDigest',v_fx_digest,
      'denominatorAmount',NULL::numeric,
      'denominatorState','UNKNOWN'::ops.funding_denominator_state,
      'denominatorUnknownReason','MISSING'::ops.funding_denominator_unknown_reason,
      'denominatorApprovalDigest',NULL::char(64),
      'denominatorApproverSetDigest',NULL::char(64),
      'denominatorApprovedAt',NULL::timestamptz,
      'denominatorApprovalExpiresAt',NULL::timestamptz,
      'entryCount',1,'entrySetDigest',v_entry_set_digest,
      'sourceSetDigest',v_source_set_digest
    )),'sha256'),'hex');

  v_import_entry:=ROW(
    1,v_group_id,v_group_digest,'RESOLVED',NULL,v_group_evidence_digest,
    '{}'::uuid[],'{}'::char(64)[],'DONATION',false,false,false,false,false,
    '{}'::uuid[],'{}'::uuid[],'{}'::char(64)[],
    '{}'::numeric(24,6)[],'{}'::uuid[],'{}'::char(64)[],
    '{}'::numeric(24,6)[],ARRAY[v_fact.id]::uuid[],
    ARRAY[v_fact.fact_digest]::char(64)[],
    ARRAY[v_fact.provider_fetch_digest]::char(64)[],
    ARRAY['DONATION'::ops.funding_source_kind],ARRAY[v_fact.amount_basis],
    ARRAY[v_fact.amount]::numeric(24,6)[],v_entry_source_set_digest,
    v_independent_review_digest,v_entry_digest
  )::ops.funding_snapshot_entry_input_v1;
  v_import:=ROW(
    'donation-funding-candidate:'||(p_input).event_id::text,
    v_batch_id,v_prior_header.id,v_prior_header.snapshot_digest,
    v_fiscal_year,v_fact.recognized_at,v_fact.currency,v_policy_version,
    v_policy_digest,v_fx_digest,'UNKNOWN',NULL,'MISSING',NULL,NULL,NULL,NULL,
    v_entry_set_digest,v_source_set_digest,v_snapshot_digest
  )::ops.funding_snapshot_import_v1;
  v_import_receipt:=ops.import_funding_snapshot_v1(
    v_import,ARRAY[v_import_entry]::ops.funding_snapshot_entry_input_v1[]
  );
  IF v_import_receipt.idempotency_replay
     OR v_import_receipt.snapshot_batch_id IS DISTINCT FROM v_batch_id
     OR v_import_receipt.snapshot_version IS DISTINCT FROM v_snapshot_version
     OR v_import_receipt.snapshot_digest IS DISTINCT FROM v_snapshot_digest
     OR v_import_receipt.entry_count IS DISTINCT FROM 1
     OR v_import_receipt.entry_set_digest IS DISTINCT FROM v_entry_set_digest
  THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_HELPER_RECEIPT_INVALID'
      USING ERRCODE='23514';
  END IF;
  SELECT header.* INTO v_header
  FROM ops.funding_concentration_snapshots AS header
  WHERE header.id=v_import_receipt.snapshot_header_id
    AND header.row_kind='SNAPSHOT_HEADER'
    AND header.snapshot_digest=v_snapshot_digest;
  SELECT entry.* INTO v_entry
  FROM ops.funding_concentration_snapshots AS entry
  WHERE entry.header_id=v_header.id AND entry.row_kind='COUNTERPARTY_ENTRY'
    AND entry.ordinal=1 AND entry.entry_digest=v_entry_digest;
  SELECT helper_audit.* INTO v_helper_audit
  FROM ops.audit_events AS helper_audit
  WHERE helper_audit.id=v_import_receipt.audit_event_id
    AND helper_audit.id=v_header.audit_event_id
    AND helper_audit.actor_type='SERVICE'
    AND helper_audit.actor_id='funding-projector'
    AND helper_audit.session_id IS NULL
    AND helper_audit.action='DONATION_FUNDING_CANDIDATE_PROJECTED'
    AND helper_audit.object_type='FundingConcentrationSnapshot'
    AND helper_audit.object_id=v_header.snapshot_batch_id::text
    AND helper_audit.capability IS NULL
    AND helper_audit.outcome='SUCCESS'
    AND helper_audit.reason='AUTHENTICATED_DONATION_FACT';
  SELECT helper_outbox.* INTO v_helper_outbox
  FROM ops.outbox AS helper_outbox
  WHERE helper_outbox.id=v_import_receipt.outbox_id
    AND helper_outbox.id=v_header.outbox_id
    AND helper_outbox.aggregate_type='FundingConcentrationSnapshot'
    AND helper_outbox.aggregate_id=v_header.snapshot_batch_id::text
    AND helper_outbox.aggregate_version=v_header.snapshot_version
    AND helper_outbox.event_type='governance.funding_snapshot_created.v1';
  v_helper_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'domain','GURINE_FUNDING_SNAPSHOT_IMPORT_RECEIPT_V1',
      'schemaVersion',1,'receiptId',v_header.id,
      'snapshotHeaderId',v_header.id,
      'snapshotBatchId',v_header.snapshot_batch_id,
      'snapshotVersion',v_header.snapshot_version,
      'snapshotDigest',v_snapshot_digest,'entryCount',1,
      'entrySetDigest',v_entry_set_digest,
      'committedAt',v_header.imported_at
    )),'sha256'),'hex');
  v_helper_response_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'receiptId',v_header.id,'snapshotHeaderId',v_header.id,
      'snapshotBatchId',v_header.snapshot_batch_id,
      'snapshotVersion',v_header.snapshot_version,
      'snapshotDigest',v_snapshot_digest,'entryCount',1,
      'entrySetDigest',v_entry_set_digest,
      'auditEventId',v_helper_audit.id,'outboxId',v_helper_outbox.id,
      'receiptDigest',v_helper_receipt_digest,
      'committedAt',v_header.imported_at
    )),'sha256'),'hex');
  v_helper_outbox_digest:=ops.r6d_outbox_envelope_digest_v1(
    v_helper_outbox.id
  );
  IF v_header.id IS NULL OR v_entry.id IS NULL OR v_helper_audit.id IS NULL
     OR v_helper_outbox.id IS NULL
     OR v_header.import_receipt_digest
       IS DISTINCT FROM v_helper_receipt_digest
     OR v_import_receipt.receipt_id IS DISTINCT FROM v_header.id
     OR v_import_receipt.receipt_digest
       IS DISTINCT FROM v_helper_receipt_digest
     OR v_import_receipt.response_digest
       IS DISTINCT FROM v_helper_response_digest
     OR v_import_receipt.committed_at IS DISTINCT FROM v_header.imported_at
     OR v_helper_audit.details IS DISTINCT FROM jsonb_build_object(
       'snapshotVersion',v_header.snapshot_version,
       'snapshotDigest',v_snapshot_digest,
       'entryCount',1,'entrySetDigest',v_entry_set_digest,
       'sourceSetDigest',v_source_set_digest,
       'authority','TEST_FIXTURE','publicationAuthority','NONE'
     )
     OR v_helper_outbox.payload IS DISTINCT FROM jsonb_build_object(
       'snapshotBatchId',v_header.snapshot_batch_id,
       'fiscalYear',v_fiscal_year,'asOf',v_fact.recognized_at,
       'reportingCurrency',v_fact.currency,
       'fxSnapshotDigest',v_fx_digest,'denominatorState','UNKNOWN',
       'denominatorUnknownReason','MISSING','denominator',NULL,
       'denominatorApprovalDigest',NULL,
       'entrySetDigest',v_entry_set_digest,
       'snapshotDigest',v_snapshot_digest,
       'receiptDigest',v_helper_receipt_digest
     )
     OR v_helper_outbox.occurred_at IS DISTINCT FROM v_header.imported_at
     OR v_helper_outbox_digest IS NULL THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_HELPER_PROOF_INVALID'
      USING ERRCODE='23514';
  END IF;

  v_now:=clock_timestamp();
  IF v_job.status IS DISTINCT FROM 'RUNNING'
     OR v_job.lease_expires_at<=v_now
     OR v_job.lease_token IS DISTINCT FROM (p_input).job_lease_token
     OR v_job.fencing_token IS DISTINCT FROM (p_input).job_fencing_token THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_LEASE_EXPIRED'
      USING ERRCODE='40001';
  END IF;
  v_job_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-donation-candidate-job-terminal.v1',
      'jobId',v_job.id,'jobType','EVENT_DELIVERY',
      'queue','projection-worker','jobVersion',v_job.version+1,
      'attempt',v_job.attempt_count,'attemptId',v_attempt.id,
      'attemptStartedAt',v_attempt.started_at,'status','SUCCEEDED',
      'jobFencingToken',(p_input).job_fencing_token,
      'leaseTokenDigest',v_lease_digest,
      'workerIdentityDigest',v_worker_digest,
      'eventId',(p_input).event_id,'inputBindingDigest',v_input_digest,
      'completedAt',v_now
    )),'sha256'),'hex');
  v_inbox_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6e-donation-candidate-inbox-terminal.v1',
      'consumer','funding-projector','eventId',(p_input).event_id,
      'receivedAt',v_inbox.received_at,'processedAt',v_now,
      'inputBindingDigest',v_input_digest,
      'candidateHeaderDigest',v_snapshot_digest,
      'candidateEntryDigest',v_entry_digest,
      'jobReceiptDigest',v_job_receipt_digest
    )),'sha256'),'hex');
  v_audit_event_id:=ops.append_audit_event(
    'funding:donation-candidate:'||(p_input).aggregate_root_fact_id::text,
    'SERVICE','funding-projector',NULL,
    'DONATION_FUNDING_CANDIDATE_PROJECTED','DonationFundingCandidate',
    (p_input).event_id::text,NULL,'SUCCESS',NULL,(p_input).job_id,
    jsonb_build_object(
      'schemaVersion','r6e-donation-funding-candidate-audit.v1',
      'jobId',(p_input).job_id,
      'jobFencingToken',(p_input).job_fencing_token,
      'eventId',(p_input).event_id,
      'aggregateRootFactId',(p_input).aggregate_root_fact_id,
      'aggregateVersion',(p_input).aggregate_version,
      'donationFactId',(p_input).donation_fact_id,
      'donationFactDigest',(p_input).donation_fact_digest,
      'candidateHeaderDigest',v_snapshot_digest,
      'candidateEntryDigest',v_entry_digest,
      'inputBindingDigest',v_input_digest,
      'sourceOutboxEnvelopeDigest',v_outbox_digest,
      'helperSnapshotReceiptDigest',v_helper_receipt_digest,
      'helperAuditEventDigest',v_helper_audit.event_hash,
      'helperOutboxEnvelopeDigest',v_helper_outbox_digest,
      'authority','TEST_FIXTURE','publicationAuthority','NONE',
      'publicMutationCount',0,'outboxEventCount',1
    )
  );
  SELECT audit.* INTO v_audit
  FROM ops.audit_events AS audit
  WHERE audit.id=v_audit_event_id
    AND audit.actor_type='SERVICE'
    AND audit.actor_id='funding-projector'
    AND audit.session_id IS NULL
    AND audit.action='DONATION_FUNDING_CANDIDATE_PROJECTED'
    AND audit.object_type='DonationFundingCandidate'
    AND audit.object_id=(p_input).event_id::text
    AND audit.capability IS NULL
    AND audit.outcome='SUCCESS'
    AND audit.reason IS NULL
    AND audit.request_id=(p_input).job_id;
  v_audit_event_digest:=v_audit.event_hash;
  IF v_audit.id IS NULL OR v_audit_event_digest IS NULL THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_AUDIT_INVALID'
      USING ERRCODE='23514';
  END IF;
  v_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','donation-funding-candidate-receipt.v1',
      'jobId',(p_input).job_id,
      'jobFencingToken',(p_input).job_fencing_token,
      'eventId',(p_input).event_id,
      'aggregateRootFactId',(p_input).aggregate_root_fact_id,
      'aggregateVersion',(p_input).aggregate_version,
      'donationFactId',(p_input).donation_fact_id,
      'donationFactDigest',(p_input).donation_fact_digest,
      'candidateHeaderDigest',v_snapshot_digest,
      'candidateEntryDigest',v_entry_digest,
      'inboxReceiptDigest',v_inbox_receipt_digest,
      'jobReceiptDigest',v_job_receipt_digest,
      'auditEventDigest',v_audit_event_digest,
      'completedAt',v_now
    )),'sha256'),'hex');

  v_result:=ROW(
    (p_input).job_id,(p_input).job_fencing_token,(p_input).event_id,
    (p_input).aggregate_root_fact_id,(p_input).aggregate_version,
    (p_input).donation_fact_id,(p_input).donation_fact_digest,
    v_snapshot_digest,v_entry_digest,v_inbox_receipt_digest,
    v_job_receipt_digest,v_audit_event_digest,v_receipt_digest,v_now
  )::ops.donation_funding_candidate_receipt_v1;
  v_expected_result:=jsonb_build_object(
    'jobId',v_result.job_id,
    'jobFencingToken',v_result.job_fencing_token,
    'eventId',v_result.event_id,
    'aggregateRootFactId',v_result.aggregate_root_fact_id,
    'aggregateVersion',v_result.aggregate_version,
    'donationFactId',v_result.donation_fact_id,
    'donationFactDigest',v_result.donation_fact_digest,
    'candidateHeaderDigest',v_result.candidate_header_digest,
    'candidateEntryDigest',v_result.candidate_entry_digest,
    'inboxReceiptDigest',v_result.inbox_receipt_digest,
    'jobReceiptDigest',v_result.job_receipt_digest,
    'auditEventDigest',v_result.audit_event_digest,
    'receiptDigest',v_result.receipt_digest,
    'completedAt',v_result.completed_at
  );
  UPDATE ops.inbox SET processed_at=v_now,result=v_expected_result::text
  WHERE consumer='funding-projector' AND event_id=(p_input).event_id
    AND processed_at IS NULL
    AND result='DISPATCHED:'||(p_input).job_id::text;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count<>1 THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_INBOX_STALE'
      USING ERRCODE='40001';
  END IF;
  UPDATE ops.job_attempts SET
    finished_at=v_now,outcome='SUCCEEDED',error_code=NULL,error_detail=NULL,
    metrics=jsonb_build_object(
      'schemaVersion','r6e-donation-candidate-job-metrics.v1',
      'eventId',(p_input).event_id,
      'candidateHeaderDigest',v_snapshot_digest,
      'candidateEntryDigest',v_entry_digest,
      'receiptDigest',v_receipt_digest
    )
  WHERE id=v_attempt.id AND job_id=(p_input).job_id
    AND attempt=v_job.attempt_count AND finished_at IS NULL
    AND worker_id=(p_input).worker_id
    AND fencing_token=(p_input).job_fencing_token;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count<>1 THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_ATTEMPT_STALE'
      USING ERRCODE='40001';
  END IF;
  UPDATE ops.jobs SET
    status='SUCCEEDED',completed_at=v_now,lease_owner=NULL,lease_token=NULL,
    lease_expires_at=NULL,version=version+1,last_error_code=NULL,
    last_error_detail=NULL,updated_at=v_now
  WHERE id=(p_input).job_id AND status='RUNNING'
    AND lease_owner=(p_input).worker_id
    AND lease_token=(p_input).job_lease_token
    AND fencing_token=(p_input).job_fencing_token
    AND lease_expires_at>v_now;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count<>1 THEN
    RAISE EXCEPTION 'R6E_DONATION_CANDIDATE_JOB_STALE'
      USING ERRCODE='40001';
  END IF;
  RETURN v_result;
END
$project_donation_fact_candidate_v1$;
ALTER FUNCTION ops.project_donation_fact_candidate_v1(
  ops.donation_funding_candidate_projection_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.project_donation_fact_candidate_v1(
  ops.donation_funding_candidate_projection_v1
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.project_donation_fact_candidate_v1(
  ops.donation_funding_candidate_projection_v1
) TO gurine_public_projector;

ALTER TABLE public.transparency_reports
  ADD COLUMN report_kind text NOT NULL DEFAULT 'GENERAL',
  ADD COLUMN source_revision_id uuid,
  ADD COLUMN source_disclosure_id uuid,
  ADD COLUMN source_revision bigint,
  ADD COLUMN source_revision_digest char(64),
  ADD COLUMN supersedes_report_id uuid,
  ADD COLUMN report_schema_version bigint,
  ADD COLUMN projection_digest char(64),
  ADD COLUMN projected_at timestamptz,
  ADD CONSTRAINT transparency_report_funding_source_fk FOREIGN KEY (
    source_revision_id,source_revision_digest
  ) REFERENCES editorial.funding_disclosure_revisions(id,revision_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT transparency_report_supersedes_fk FOREIGN KEY (
    supersedes_report_id
  ) REFERENCES public.transparency_reports(id) ON DELETE RESTRICT,
  ADD CONSTRAINT transparency_report_funding_source_uq
    UNIQUE (source_revision_id),
  ADD CONSTRAINT transparency_report_funding_series_revision_uq
    UNIQUE (source_disclosure_id,source_revision),
  ADD CONSTRAINT transparency_report_projection_digest_uq
    UNIQUE (projection_digest),
  ADD CONSTRAINT transparency_report_kind_ck CHECK (
    report_kind IN ('GENERAL','FUNDING_DISCLOSURE')
  ),
  ADD CONSTRAINT transparency_report_funding_shape_ck CHECK (
    report_kind='GENERAL'
    AND source_revision_id IS NULL
    AND source_disclosure_id IS NULL
    AND source_revision IS NULL
    AND source_revision_digest IS NULL
    AND supersedes_report_id IS NULL
    AND report_schema_version IS NULL
    AND projection_digest IS NULL
    AND projected_at IS NULL
    OR report_kind='FUNDING_DISCLOSURE'
    AND source_revision_id IS NOT NULL
    AND source_disclosure_id IS NOT NULL
    AND source_revision IS NOT NULL
    AND source_revision>0
    AND source_revision_digest IS NOT NULL
    AND report_schema_version=1
    AND projection_digest IS NOT NULL
    AND projected_at IS NOT NULL
  ),
  ADD CONSTRAINT transparency_report_funding_digest_ck CHECK (
    source_revision_digest IS NULL
    OR source_revision_digest~'^[0-9a-f]{64}$'
       AND projection_digest~'^[0-9a-f]{64}$'
  ),
  ADD CONSTRAINT transparency_report_funding_time_ck CHECK (
    projected_at IS NULL OR published_at<=projected_at
  );

CREATE INDEX transparency_report_funding_source_fk_idx
  ON public.transparency_reports(source_revision_id,source_revision_digest,id)
  WHERE source_revision_id IS NOT NULL;
CREATE INDEX transparency_report_funding_history_idx
  ON public.transparency_reports(source_disclosure_id,source_revision ASC,id ASC)
  WHERE report_kind='FUNDING_DISCLOSURE';
CREATE INDEX transparency_report_funding_period_idx
  ON public.transparency_reports(
    period_end DESC,period_start DESC,published_at DESC,id DESC
  ) WHERE report_kind='FUNDING_DISCLOSURE';
CREATE INDEX transparency_report_supersedes_fk_idx
  ON public.transparency_reports(supersedes_report_id,id)
  WHERE supersedes_report_id IS NOT NULL;

CREATE TYPE public.funding_disclosure_projection_v2 AS (
  event_id uuid,
  disclosure_id uuid,
  revision_id uuid,
  revision bigint,
  revision_digest char(64),
  snapshot_batch_id uuid,
  snapshot_digest char(64),
  concentration_band editorial.funding_concentration_band,
  entry_set_digest char(64),
  prior_revision bigint,
  effective_at timestamptz,
  receipt_digest char(64),
  job_id uuid,
  job_lease_token uuid,
  job_fencing_token bigint
);
CREATE TYPE public.projection_mutation_receipt_v2 AS (
  operation_id text,
  event_id uuid,
  source_aggregate_id uuid,
  source_aggregate_version bigint,
  source_aggregate_digest char(64),
  projection_id uuid,
  projection_version bigint,
  projection_digest char(64),
  projected_row_count bigint,
  inbox_receipt_digest char(64),
  job_receipt_digest char(64),
  audit_event_id uuid,
  outbox_event_ids uuid[],
  receipt_digest char(64),
  completed_at timestamptz
);
REVOKE ALL ON TYPE public.funding_disclosure_projection_v2,
  public.projection_mutation_receipt_v2 FROM PUBLIC;

CREATE FUNCTION public.guard_funding_transparency_report_mutation_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path=pg_catalog,public,pg_temp
AS $$
BEGIN
  IF (TG_OP='DELETE' AND OLD.report_kind='FUNDING_DISCLOSURE')
     OR (TG_OP='UPDATE' AND (
       OLD.report_kind='FUNDING_DISCLOSURE'
       OR NEW.report_kind='FUNDING_DISCLOSURE'
     )) THEN
    RAISE EXCEPTION 'FUNDING_TRANSPARENCY_REPORT_IMMUTABLE'
      USING ERRCODE='55000';
  END IF;
  IF TG_OP='DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION public.guard_funding_transparency_report_mutation_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  public.guard_funding_transparency_report_mutation_v1() FROM PUBLIC;
CREATE TRIGGER public_funding_transparency_report_immutable
  BEFORE UPDATE OR DELETE ON public.transparency_reports
  FOR EACH ROW EXECUTE FUNCTION
    public.guard_funding_transparency_report_mutation_v1();

-- R6E_PUBLIC_PROJECTION_OWNER_FUNCTIONS

CREATE FUNCTION editorial.read_public_funding_projection_inputs_v1(
  p_revision_id uuid,
  p_expected_revision_digest char(64)
) RETURNS SETOF editorial.funding_public_projection_input_v1
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,public,pg_temp
SET timezone='UTC'
AS $r6e_public_funding_reader$
DECLARE
  v_revision editorial.funding_disclosure_revisions%ROWTYPE;
  v_header ops.funding_concentration_snapshots%ROWTYPE;
  v_entry editorial.funding_disclosure_entries%ROWTYPE;
  v_public_revision editorial.funding_public_revision_v1;
  v_public_entries editorial.funding_public_entry_v1[]:=
    ARRAY[]::editorial.funding_public_entry_v1[];
  v_public_case_refs text[];
  v_public_source_links text[];
  v_all_public_source_links text[]:='{}'::text[];
  v_source_group_ids uuid[];
  v_expected_source_ids uuid[];
  v_expected_source_digests char(64)[];
  v_evidence_document_ids uuid[];
  v_evidence_asset_ids uuid[];
  v_hold_targets uuid[];
  v_hold_id uuid;
  v_hold_resolution jsonb;
  v_now timestamptz:=clock_timestamp();
  v_entry_count bigint;
  v_min_ordinal integer;
  v_max_ordinal integer;
  v_distinct_ordinal_count bigint;
  v_snapshot_entry_count bigint;
  v_partition_entry_count bigint;
  v_partition_distinct_count bigint;
  v_public_case_count bigint;
  v_public_source_count bigint;
  v_independent_review_count bigint;
  v_source_snapshot_members jsonb;
  v_counterparty_group_members jsonb;
  v_independent_review_members jsonb;
  v_conditional_gate_members jsonb;
  v_entry_digest_members jsonb:='[]'::jsonb;
  v_expected_digest char(64);
BEGIN
  IF p_revision_id IS NULL
     OR p_expected_revision_digest IS NULL
     OR btrim(p_expected_revision_digest::text)!~'^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_INPUT_INVALID'
      USING ERRCODE='22023';
  END IF;
  -- 0029 does not freeze an executable private entry/revision digest
  -- preimage.  No source row may cross the public boundary until that ABI is
  -- supplied by higher authority; relational and rights checks cannot invent
  -- the missing byte contract.
  RAISE EXCEPTION 'FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE'
    USING ERRCODE='55000';

  SELECT revision.* INTO v_revision
  FROM editorial.funding_disclosure_revisions AS revision
  WHERE revision.id=p_revision_id
    AND revision.revision_digest=p_expected_revision_digest
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT header.* INTO v_header
  FROM ops.funding_concentration_snapshots AS header
  WHERE header.id=v_revision.snapshot_header_id
    AND header.snapshot_batch_id=v_revision.snapshot_batch_id
    AND header.snapshot_digest=v_revision.snapshot_digest
    AND header.row_kind='SNAPSHOT_HEADER'
  FOR SHARE;
  IF NOT FOUND
     OR v_header.fiscal_year IS DISTINCT FROM v_revision.fiscal_year
     OR v_header.reporting_currency IS DISTINCT FROM v_revision.reporting_currency
     OR v_header.funding_policy_version IS DISTINCT FROM
        v_revision.funding_policy_version
     OR v_header.funding_policy_digest IS DISTINCT FROM
        v_revision.funding_policy_digest THEN
    RETURN;
  END IF;

  PERFORM disclosure_entry.id
  FROM editorial.funding_disclosure_entries AS disclosure_entry
  WHERE disclosure_entry.revision_id=v_revision.id
  ORDER BY disclosure_entry.ordinal,disclosure_entry.id
  FOR SHARE;
  SELECT count(*),min(disclosure_entry.ordinal),max(disclosure_entry.ordinal),
         count(DISTINCT disclosure_entry.ordinal)
  INTO v_entry_count,v_min_ordinal,v_max_ordinal,v_distinct_ordinal_count
  FROM editorial.funding_disclosure_entries AS disclosure_entry
  WHERE disclosure_entry.revision_id=v_revision.id;
  IF v_entry_count IS DISTINCT FROM v_revision.entry_count::bigint
     OR v_distinct_ordinal_count IS DISTINCT FROM v_entry_count
     OR (v_entry_count=0 AND (
       v_min_ordinal IS NOT NULL OR v_max_ordinal IS NOT NULL
     ))
     OR (v_entry_count>0 AND (
       v_min_ordinal IS DISTINCT FROM 1
       OR v_max_ordinal IS DISTINCT FROM v_entry_count::integer
     )) THEN
    RETURN;
  END IF;

  PERFORM snapshot_entry.id
  FROM ops.funding_concentration_snapshots AS snapshot_entry
  WHERE snapshot_entry.header_id=v_header.id
    AND snapshot_entry.snapshot_batch_id=v_header.snapshot_batch_id
    AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
  ORDER BY snapshot_entry.ordinal,snapshot_entry.id
  FOR SHARE;
  SELECT count(*),min(snapshot_entry.ordinal),max(snapshot_entry.ordinal),
         count(DISTINCT snapshot_entry.ordinal)
  INTO v_snapshot_entry_count,v_min_ordinal,v_max_ordinal,
       v_distinct_ordinal_count
  FROM ops.funding_concentration_snapshots AS snapshot_entry
  WHERE snapshot_entry.header_id=v_header.id
    AND snapshot_entry.snapshot_batch_id=v_header.snapshot_batch_id
    AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY';
  IF v_snapshot_entry_count IS DISTINCT FROM v_header.entry_count::bigint
     OR v_distinct_ordinal_count IS DISTINCT FROM v_snapshot_entry_count
     OR (v_snapshot_entry_count=0 AND (
       v_min_ordinal IS NOT NULL OR v_max_ordinal IS NOT NULL
     ))
     OR (v_snapshot_entry_count>0 AND (
       v_min_ordinal IS DISTINCT FROM 1
       OR v_max_ordinal IS DISTINCT FROM v_snapshot_entry_count::integer
     )) THEN
    RETURN;
  END IF;

  SELECT count(*),count(DISTINCT source.source_id)
  INTO v_partition_entry_count,v_partition_distinct_count
  FROM editorial.funding_disclosure_entries AS disclosure_entry
  CROSS JOIN LATERAL unnest(
    disclosure_entry.source_snapshot_entry_ids
  ) AS source(source_id)
  WHERE disclosure_entry.revision_id=v_revision.id;
  IF v_partition_entry_count IS DISTINCT FROM v_snapshot_entry_count
     OR v_partition_distinct_count IS DISTINCT FROM v_snapshot_entry_count
     OR EXISTS (
       SELECT 1
       FROM editorial.funding_disclosure_entries AS disclosure_entry
       CROSS JOIN LATERAL unnest(
         disclosure_entry.source_snapshot_entry_ids,
         disclosure_entry.source_snapshot_entry_digests
       ) AS source(source_id,source_digest)
       LEFT JOIN ops.funding_concentration_snapshots AS snapshot_entry
         ON snapshot_entry.id=source.source_id
        AND snapshot_entry.entry_digest=source.source_digest
        AND snapshot_entry.header_id=v_header.id
        AND snapshot_entry.snapshot_batch_id=v_header.snapshot_batch_id
        AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
       WHERE disclosure_entry.revision_id=v_revision.id
         AND snapshot_entry.id IS NULL
     ) THEN
    RETURN;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'ordinal',snapshot_entry.ordinal,
    'sourceSnapshotEntryId',snapshot_entry.id,
    'sourceSnapshotEntryDigest',btrim(snapshot_entry.entry_digest::text),
    'concentrationBand',snapshot_entry.concentration_band::text,
    'concentrationUnknownReason',snapshot_entry.concentration_unknown_reason::text,
    'governmentRelated',snapshot_entry.government_related,
    'politicalPartyRelated',snapshot_entry.political_party_related,
    'procurementSupplierRelated',snapshot_entry.procurement_supplier_related,
    'investigatedSubjectRelated',snapshot_entry.investigated_subject_related,
    'relatedParty',snapshot_entry.related_party,
    'relatedCaseIds',to_jsonb(snapshot_entry.related_case_ids)
  ) ORDER BY snapshot_entry.ordinal,snapshot_entry.id),'[]'::jsonb)
  INTO v_conditional_gate_members
  FROM ops.funding_concentration_snapshots AS snapshot_entry
  WHERE snapshot_entry.header_id=v_header.id
    AND snapshot_entry.snapshot_batch_id=v_header.snapshot_batch_id
    AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
    AND (
      snapshot_entry.concentration_band IN (
        'GT_15_TO_25_PERCENT','GT_25_PERCENT','UNKNOWN'
      )
      OR (
        (snapshot_entry.investigated_subject_related
          OR snapshot_entry.related_party)
        AND snapshot_entry.concentration_band IN (
          'GT_5_TO_15_PERCENT','GT_15_TO_25_PERCENT','GT_25_PERCENT'
        )
      )
    );
  v_expected_digest:=
    editorial.funding_disclosure_conditional_gate_set_digest_v1(
      v_conditional_gate_members
    );
  IF v_revision.conditional_gate_set_digest<>v_expected_digest
     OR v_revision.requires_oversight_review IS DISTINCT FROM EXISTS (
       SELECT 1 FROM ops.funding_concentration_snapshots AS snapshot_entry
       WHERE snapshot_entry.header_id=v_header.id
         AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
         AND snapshot_entry.concentration_band IN (
           'GT_15_TO_25_PERCENT','GT_25_PERCENT','UNKNOWN'
         )
     )
     OR v_revision.requires_board_approval IS DISTINCT FROM EXISTS (
       SELECT 1 FROM ops.funding_concentration_snapshots AS snapshot_entry
       WHERE snapshot_entry.header_id=v_header.id
         AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
         AND snapshot_entry.concentration_band IN ('GT_25_PERCENT','UNKNOWN')
     )
     OR v_revision.requires_enhanced_public_disclosure IS DISTINCT FROM EXISTS (
       SELECT 1 FROM ops.funding_concentration_snapshots AS snapshot_entry
       WHERE snapshot_entry.header_id=v_header.id
         AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
         AND snapshot_entry.concentration_band IN ('GT_25_PERCENT','UNKNOWN')
     )
     OR v_revision.has_related_party_gate IS DISTINCT FROM EXISTS (
       SELECT 1 FROM ops.funding_concentration_snapshots AS snapshot_entry
       WHERE snapshot_entry.header_id=v_header.id
         AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
         AND (snapshot_entry.investigated_subject_related
           OR snapshot_entry.related_party)
         AND snapshot_entry.concentration_band IN (
           'GT_5_TO_15_PERCENT','GT_15_TO_25_PERCENT','GT_25_PERCENT'
         )
     ) THEN
    RETURN;
  END IF;

  v_hold_targets:=ARRAY[
    v_revision.id,v_revision.disclosure_id,v_revision.snapshot_header_id,
    v_revision.snapshot_batch_id,v_revision.conflict_snapshot_id,
    v_revision.proposal_id,v_revision.execution_id,
    v_revision.preparer_decision_id,v_revision.publisher_decision_id,
    v_revision.oversight_decision_id,v_revision.board_decision_id,
    v_revision.prepared_by_user_id,v_revision.published_by_user_id,
    v_revision.oversight_reviewer_user_id,v_revision.board_approver_user_id,
    v_revision.execution_receipt_id,v_revision.audit_event_id,
    v_revision.outbox_id
  ]::uuid[]||v_revision.independent_case_review_decision_ids;
  FOR v_entry IN
    SELECT disclosure_entry.*
    FROM editorial.funding_disclosure_entries AS disclosure_entry
    WHERE disclosure_entry.revision_id=v_revision.id
    ORDER BY disclosure_entry.ordinal,disclosure_entry.id
  LOOP
    IF v_entry.disclosure_id IS DISTINCT FROM v_revision.disclosure_id
       OR v_entry.revision IS DISTINCT FROM v_revision.revision
       OR v_entry.snapshot_batch_id IS DISTINCT FROM v_revision.snapshot_batch_id
       OR v_entry.snapshot_digest IS DISTINCT FROM v_revision.snapshot_digest
       OR v_entry.reporting_currency IS DISTINCT FROM
          v_revision.reporting_currency
       OR v_entry.source_snapshot_entry_ids IS DISTINCT FROM COALESCE((
         SELECT array_agg(snapshot_entry.id ORDER BY
                  snapshot_entry.ordinal,snapshot_entry.id)
         FROM ops.funding_concentration_snapshots AS snapshot_entry
         WHERE snapshot_entry.header_id=v_header.id
           AND snapshot_entry.snapshot_batch_id=v_header.snapshot_batch_id
           AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
           AND snapshot_entry.id=ANY(v_entry.source_snapshot_entry_ids)
       ),'{}'::uuid[])
       OR v_entry.source_snapshot_entry_digests IS DISTINCT FROM COALESCE((
         SELECT array_agg(snapshot_entry.entry_digest ORDER BY
                  snapshot_entry.ordinal,snapshot_entry.id)
         FROM ops.funding_concentration_snapshots AS snapshot_entry
         WHERE snapshot_entry.header_id=v_header.id
           AND snapshot_entry.snapshot_batch_id=v_header.snapshot_batch_id
           AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
           AND snapshot_entry.id=ANY(v_entry.source_snapshot_entry_ids)
       ),'{}'::char(64)[])
       OR v_entry.related_case_ids IS DISTINCT FROM COALESCE((
         SELECT array_agg(case_id ORDER BY case_id)
         FROM (SELECT DISTINCT case_id
               FROM unnest(v_entry.related_case_ids) AS ids(case_id)) AS cases
       ),'{}'::uuid[])
       OR v_entry.evidence_ids IS DISTINCT FROM COALESCE((
         SELECT array_agg(evidence_id ORDER BY evidence_id)
         FROM (SELECT DISTINCT evidence_id
               FROM unnest(v_entry.evidence_ids) AS ids(evidence_id)) AS evidence
       ),'{}'::uuid[])
       OR (v_entry.independent_review_required AND (
         cardinality(v_entry.independent_review_decision_ids)<>
           cardinality(v_entry.related_case_ids)
         OR cardinality(v_entry.independent_review_decision_ids)<>
           (SELECT count(DISTINCT decision_id)
            FROM unnest(v_entry.independent_review_decision_ids)
              AS decisions(decision_id))
       ))
       OR (NOT v_entry.independent_review_required
         AND cardinality(v_entry.independent_review_decision_ids)<>0) THEN
      RETURN;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'sourceSnapshotEntryId',snapshot_entry.id,
      'sourceSnapshotEntryDigest',btrim(snapshot_entry.entry_digest::text)
    ) ORDER BY snapshot_entry.ordinal,snapshot_entry.id),'[]'::jsonb),
      COALESCE(jsonb_agg(jsonb_build_object(
        'counterpartyGroupId',snapshot_entry.counterparty_group_id,
        'counterpartyGroupDigest',
          btrim(snapshot_entry.counterparty_group_digest::text)
      ) ORDER BY snapshot_entry.ordinal,snapshot_entry.id),'[]'::jsonb),
      COALESCE(array_agg(snapshot_entry.counterparty_group_id ORDER BY
        snapshot_entry.ordinal,snapshot_entry.id),'{}'::uuid[])
    INTO v_source_snapshot_members,v_counterparty_group_members,
         v_source_group_ids
    FROM ops.funding_concentration_snapshots AS snapshot_entry
    WHERE snapshot_entry.header_id=v_header.id
      AND snapshot_entry.snapshot_batch_id=v_header.snapshot_batch_id
      AND snapshot_entry.row_kind='COUNTERPARTY_ENTRY'
      AND snapshot_entry.id=ANY(v_entry.source_snapshot_entry_ids);
    v_expected_digest:=
      editorial.funding_disclosure_source_entry_set_digest_v1(
        v_source_snapshot_members
      );
    IF v_entry.source_snapshot_entry_set_digest<>v_expected_digest THEN
      RETURN;
    END IF;
    v_expected_digest:=
      editorial.funding_disclosure_counterparty_group_set_digest_v1(
        v_counterparty_group_members
      );
    IF v_entry.source_counterparty_group_set_digest<>v_expected_digest THEN
      RETURN;
    END IF;
    IF v_entry.independent_review_required THEN
      PERFORM decision.id
      FROM unnest(
        v_entry.related_case_ids,v_entry.independent_review_decision_ids
      ) WITH ORDINALITY AS review(case_id,decision_id,ordinal)
      JOIN ops.action_decisions AS decision ON decision.id=review.decision_id
      ORDER BY review.ordinal
      FOR SHARE OF decision;
      SELECT count(decision.id),COALESCE(jsonb_agg(jsonb_build_object(
        'relatedCaseId',review.case_id,
        'decisionId',review.decision_id,
        'decisionReceiptDigest',btrim(decision.receipt_digest::text)
      ) ORDER BY review.ordinal),'[]'::jsonb)
      INTO v_independent_review_count,v_independent_review_members
      FROM unnest(
        v_entry.related_case_ids,v_entry.independent_review_decision_ids
      ) WITH ORDINALITY AS review(case_id,decision_id,ordinal)
      JOIN ops.action_decisions AS decision ON decision.id=review.decision_id;
      IF v_independent_review_count IS DISTINCT FROM
         cardinality(v_entry.related_case_ids)::bigint THEN
        RETURN;
      END IF;
    ELSE
      v_independent_review_members:='[]'::jsonb;
    END IF;
    v_expected_digest:=
      editorial.funding_disclosure_independent_review_set_digest_v1(
        v_independent_review_members
      );
    IF v_entry.independent_review_set_digest<>v_expected_digest THEN
      RETURN;
    END IF;

    PERFORM public_case.id
    FROM public.cases AS public_case
    WHERE public_case.id=ANY(v_entry.related_case_ids)
    ORDER BY public_case.id
    FOR SHARE;
    SELECT count(*),COALESCE(array_agg(
      '/cases/'||public_case.slug ORDER BY
      ('/cases/'||public_case.slug) COLLATE "C"
    ),'{}'::text[])
    INTO v_public_case_count,v_public_case_refs
    FROM public.cases AS public_case
    WHERE public_case.id=ANY(v_entry.related_case_ids)
      AND length(public_case.slug) BETWEEN 1 AND 200
      AND public_case.slug!~'[/?#[:space:]\\]';
    IF v_public_case_count IS DISTINCT FROM
       cardinality(v_entry.related_case_ids)::bigint THEN
      RETURN;
    END IF;

    PERFORM evidence.id
    FROM editorial.evidence AS evidence
    WHERE evidence.id=ANY(v_entry.evidence_ids)
    ORDER BY evidence.id
    FOR SHARE;
    PERFORM source_document.id
    FROM raw.source_documents AS source_document
    JOIN editorial.evidence AS evidence
      ON evidence.source_document_id=source_document.id
    WHERE evidence.id=ANY(v_entry.evidence_ids)
    ORDER BY source_document.id
    FOR SHARE OF source_document;
    PERFORM source_registry.source_id
    FROM ops.source_registry AS source_registry
    JOIN raw.source_documents AS source_document
      ON source_document.source_id=source_registry.source_id
    JOIN editorial.evidence AS evidence
      ON evidence.source_document_id=source_document.id
    WHERE evidence.id=ANY(v_entry.evidence_ids)
    ORDER BY source_registry.source_id
    FOR SHARE OF source_registry;

    SELECT count(*),
      COALESCE(array_agg(DISTINCT source_document.canonical_url ORDER BY
        source_document.canonical_url COLLATE "C"),'{}'::text[]),
      COALESCE(array_agg(DISTINCT source_document.id ORDER BY
        source_document.id),'{}'::uuid[]),
      COALESCE(array_agg(DISTINCT source_document.asset_id ORDER BY
        source_document.asset_id),'{}'::uuid[])
    INTO v_public_source_count,v_public_source_links,
         v_evidence_document_ids,v_evidence_asset_ids
    FROM editorial.evidence AS evidence
    JOIN raw.source_documents AS source_document
      ON source_document.id=evidence.source_document_id
    JOIN ops.source_registry AS source_registry
      ON source_registry.source_id=source_document.source_id
    JOIN LATERAL (
      SELECT rights.*
      FROM raw.asset_rights_decisions AS rights
      WHERE rights.asset_id=source_document.asset_id
        AND rights.asset_revision=source_document.asset_revision
        AND rights.asset_sha256=source_document.content_sha256
      ORDER BY rights.decision_version DESC,rights.id DESC
      LIMIT 1
    ) AS rights ON true
    WHERE evidence.id=ANY(v_entry.evidence_ids)
      AND evidence.classification='PUBLIC'
      AND evidence.verification_status='VERIFIED'
      AND source_registry.legal_status='APPROVED'
      AND source_document.canonical_url IS NOT NULL
      AND length(source_document.canonical_url) BETWEEN 9 AND 2048
      AND source_document.canonical_url LIKE 'https://%'
      AND source_document.canonical_url!~'[@[:space:]\\]'
      AND substring(source_document.canonical_url FROM 9)!~'^[/?:#]'
      AND rights.decision_kind='GRANT'
      AND rights.access_right='ALLOW'
      AND rights.excerpt_right='ALLOW'
      AND rights.redistribution_right='ALLOW'
      AND rights.public_display_right='ALLOW'
      AND rights.effective_at<=v_now
      AND (rights.expires_at IS NULL OR rights.expires_at>v_now);
    IF v_public_source_count IS DISTINCT FROM
       cardinality(v_entry.evidence_ids)::bigint
       OR cardinality(v_public_source_links)=0 THEN
      RETURN;
    END IF;
    v_expected_digest:=
      editorial.funding_disclosure_source_link_set_digest_v1(
        v_public_source_links
      );
    IF v_entry.source_link_set_digest<>v_expected_digest THEN
      RETURN;
    END IF;
    v_expected_digest:=editorial.funding_disclosure_entry_digest_v1(
      (to_jsonb(v_entry)-'entry_digest')-'created_at'
    );
    IF v_entry.entry_digest<>v_expected_digest THEN
      RETURN;
    END IF;
    v_entry_digest_members:=v_entry_digest_members||jsonb_build_array(
      jsonb_build_object(
        'ordinal',v_entry.ordinal,
        'entryDigest',btrim(v_entry.entry_digest::text)
      )
    );
    v_all_public_source_links:=v_all_public_source_links||v_public_source_links;

    v_public_entries:=array_append(v_public_entries,ROW(
      v_entry.ordinal,v_entry.identity_disclosure_mode,
      v_entry.public_display_name,v_entry.withholding_public_explanation,
      v_entry.counterparty_category,v_entry.funding_source_kind,
      v_entry.amount_band_lower,v_entry.amount_band_upper,
      v_entry.reporting_currency,v_entry.concentration_band,
      v_entry.denominator_unknown_reason,v_entry.grouping_dispute_reason,
      v_entry.concentration_unknown_reason,v_entry.public_caveat_text,
      v_entry.purpose,v_entry.conflict_disclosure,
      v_entry.mitigation_summary,v_entry.government_related,
      v_entry.political_party_related,v_entry.procurement_supplier_related,
      v_entry.investigated_subject_related,v_entry.related_party,
      v_public_case_refs,v_public_source_links,v_entry.entry_digest
    )::editorial.funding_public_entry_v1);
    v_hold_targets:=v_hold_targets||ARRAY[v_entry.id]::uuid[]
      ||v_entry.source_snapshot_entry_ids||v_entry.related_case_ids
      ||v_entry.independent_review_decision_ids||v_entry.evidence_ids
      ||v_source_group_ids||v_evidence_document_ids||v_evidence_asset_ids;
  END LOOP;

  v_expected_digest:=editorial.funding_disclosure_entry_set_digest_v1(
    v_revision.entry_count,v_entry_digest_members
  );
  IF v_revision.entry_set_digest<>v_expected_digest THEN
    RETURN;
  END IF;
  SELECT COALESCE(array_agg(DISTINCT source_link ORDER BY
    source_link COLLATE "C"),'{}'::text[])
  INTO v_all_public_source_links
  FROM unnest(v_all_public_source_links) AS links(source_link);
  v_expected_digest:=
    editorial.funding_disclosure_source_link_set_digest_v1(
      v_all_public_source_links
    );
  IF v_revision.source_link_set_digest<>v_expected_digest THEN
    RETURN;
  END IF;
  v_expected_digest:=
    editorial.funding_disclosure_policy_request_outcome_digest_v1(
      v_revision.policy_request_total,v_revision.policy_request_accepted,
      v_revision.policy_request_partially_accepted,
      v_revision.policy_request_rejected,v_revision.policy_request_withdrawn,
      v_revision.policy_request_pending
    );
  IF v_revision.policy_request_outcome_digest<>v_expected_digest THEN
    RETURN;
  END IF;

  v_public_revision:=ROW(
    v_revision.disclosure_id,v_revision.revision,v_revision.prior_revision,
    v_revision.fiscal_year,v_revision.fiscal_quarter,
    v_revision.period_start,v_revision.period_end,
    v_revision.reporting_currency,v_revision.concentration_band,
    v_revision.unknown_reason,v_revision.public_caveat_text,
    v_revision.purpose,v_revision.policy_request_total,
    v_revision.policy_request_accepted,
    v_revision.policy_request_partially_accepted,
    v_revision.policy_request_rejected,v_revision.policy_request_withdrawn,
    v_revision.policy_request_pending,v_revision.policy_request_outcome_digest,
    v_revision.source_link_set_digest,v_revision.entry_count,
    v_revision.entry_set_digest,v_revision.funding_policy_version,
    v_revision.funding_policy_digest,v_revision.effective_at,
    v_revision.published_at,v_revision.public_content_digest,
    v_revision.revision_digest,v_revision.requires_enhanced_public_disclosure
  )::editorial.funding_public_revision_v1;
  v_expected_digest:=
    editorial.funding_disclosure_public_content_digest_v1(
      v_public_revision,v_public_entries
    );
  IF v_revision.public_content_digest<>v_expected_digest THEN
    RETURN;
  END IF;
  v_expected_digest:=editorial.funding_disclosure_revision_digest_v1(
    (to_jsonb(v_revision)-'revision_digest')-'created_at'
  );
  IF v_revision.revision_digest<>v_expected_digest
     OR p_expected_revision_digest<>v_expected_digest THEN
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT target_id ORDER BY target_id),'{}'::uuid[])
  INTO v_hold_targets
  FROM unnest(v_hold_targets) AS targets(target_id)
  WHERE target_id IS NOT NULL;
  FOR v_hold_id IN
    SELECT DISTINCT placement.legal_hold_id
    FROM ops.legal_hold_placement_receipts_v2 AS placement
    WHERE placement.placed_at<=v_now
      AND placement.affected_ids&&v_hold_targets
    ORDER BY placement.legal_hold_id
  LOOP
    v_hold_resolution:=ops.r6d_legal_hold_cell_resolution_v1(
      v_hold_id,v_now
    );
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(
        v_hold_resolution->'activeCells'
      ) AS active_cell(value)
      WHERE active_cell.value->>'scopeAtom'='DISCLOSURE'
        AND (active_cell.value->>'affectedId')::uuid=ANY(v_hold_targets)
    ) THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_DISCLOSURE_HELD'
        USING ERRCODE='55000';
    END IF;
  END LOOP;

  RETURN NEXT ROW(
    v_public_revision,v_public_entries
  )::editorial.funding_public_projection_input_v1;
  RETURN;
END
$r6e_public_funding_reader$;
ALTER FUNCTION editorial.read_public_funding_projection_inputs_v1(
  uuid,char(64)
) OWNER TO gurine_migrator;

CREATE FUNCTION public.project_funding_disclosure_revision_v2(
  p_projection public.funding_disclosure_projection_v2
) RETURNS public.projection_mutation_receipt_v2
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,public,editorial,ops,pg_temp
SET timezone='UTC'
AS $r6e_public_funding_projector$
DECLARE
  v_operation_id constant text:=
    'ECONOMICS.PROJECT_FUNDING_DISCLOSURE.V2';
  v_outbox ops.outbox%ROWTYPE;
  v_source editorial.funding_disclosure_revisions%ROWTYPE;
  v_inbox ops.inbox%ROWTYPE;
  v_job ops.jobs%ROWTYPE;
  v_attempt ops.job_attempts%ROWTYPE;
  v_report public.transparency_reports%ROWTYPE;
  v_prior_report public.transparency_reports%ROWTYPE;
  v_head_report public.transparency_reports%ROWTYPE;
  v_prior_report_id uuid;
  v_audit ops.audit_events%ROWTYPE;
  v_public_input editorial.funding_public_projection_input_v1;
  v_public_entry editorial.funding_public_entry_v1;
  v_public_input_count integer:=0;
  v_job_id uuid;
  v_report_id uuid;
  v_audit_event_id uuid;
  v_completed_at timestamptz;
  v_effective_at_text text;
  v_published_at_text text;
  v_title text;
  v_summary text:='승인된 재원 공개 개정본';
  v_sources text[]:='{}'::text[];
  v_report_entries jsonb:='[]'::jsonb;
  v_report_json jsonb;
  v_projection_preimage jsonb;
  v_projection_digest char(64);
  v_inbox_preimage jsonb;
  v_inbox_receipt_digest char(64);
  v_job_payload_digest char(64);
  v_job_lease_token_digest char(64);
  v_job_preimage jsonb;
  v_job_receipt_digest char(64);
  v_receipt_preimage jsonb;
  v_receipt_digest char(64);
  v_metrics jsonb;
  v_audit_details jsonb;
  v_receipt public.projection_mutation_receipt_v2;
  v_existing_report boolean:=false;
  v_changed bigint;
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_public_projector'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF current_setting('transaction_isolation')<>'serializable' THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_REQUIRES_SERIALIZABLE'
      USING ERRCODE='25001';
  END IF;
  IF p_projection IS NULL
     OR p_projection.event_id IS NULL
     OR p_projection.disclosure_id IS NULL
     OR p_projection.revision_id IS NULL
     OR p_projection.revision IS NULL OR p_projection.revision<1
     OR p_projection.revision_digest IS NULL
     OR btrim(p_projection.revision_digest::text)!~'^[0-9a-f]{64}$'
     OR p_projection.snapshot_batch_id IS NULL
     OR p_projection.snapshot_digest IS NULL
     OR btrim(p_projection.snapshot_digest::text)!~'^[0-9a-f]{64}$'
     OR p_projection.concentration_band IS NULL
     OR p_projection.entry_set_digest IS NULL
     OR btrim(p_projection.entry_set_digest::text)!~'^[0-9a-f]{64}$'
     OR p_projection.effective_at IS NULL
     OR p_projection.receipt_digest IS NULL
     OR btrim(p_projection.receipt_digest::text)!~'^[0-9a-f]{64}$'
     OR p_projection.job_id IS NULL
     OR p_projection.job_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_projection.job_lease_token IS NULL
     OR p_projection.job_lease_token=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR p_projection.job_fencing_token IS NULL
     OR p_projection.job_fencing_token<1
     OR (p_projection.revision=1 AND p_projection.prior_revision IS NOT NULL)
     OR (p_projection.revision>1 AND p_projection.prior_revision IS DISTINCT FROM
       p_projection.revision-1) THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_INPUT_INVALID'
      USING ERRCODE='22023';
  END IF;
  -- This latch precedes every source read and mutation, including replay.
  -- Stored digests cannot authorize publication while their canonical private
  -- preimage ABI remains unspecified.
  RAISE EXCEPTION 'FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE'
    USING ERRCODE='55000';
  v_job_lease_token_digest:=encode(extensions.digest(
    convert_to(p_projection.job_lease_token::text,'UTF8'),'sha256'
  ),'hex');

  SELECT event.* INTO v_outbox
  FROM ops.outbox AS event
  WHERE event.id=p_projection.event_id
  FOR SHARE;
  SELECT source.* INTO v_source
  FROM editorial.funding_disclosure_revisions AS source
  WHERE source.outbox_id=p_projection.event_id
  FOR SHARE;
  IF v_outbox.id IS NULL OR v_source.id IS NULL THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_SOURCE_UNAVAILABLE'
      USING ERRCODE='55000';
  END IF;
  IF v_outbox.event_type<>'governance.funding_disclosure_published.v1'
     OR v_outbox.aggregate_type<>'FundingDisclosureRevision'
     OR v_outbox.aggregate_id<>v_source.id::text
     OR v_outbox.aggregate_version<>v_source.revision
     OR jsonb_typeof(v_outbox.payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_outbox.payload))<>11
     OR NOT v_outbox.payload?&ARRAY[
       'disclosureId','revisionId','revision','revisionDigest',
       'snapshotBatchId','snapshotDigest','concentrationBand','entrySetDigest',
       'priorRevision','effectiveAt','receiptDigest'
     ]
     OR v_outbox.payload->>'disclosureId'<>v_source.disclosure_id::text
     OR v_outbox.payload->>'revisionId'<>v_source.id::text
     OR (v_outbox.payload->>'revision')::bigint<>v_source.revision
     OR v_outbox.payload->>'revisionDigest'<>
        btrim(v_source.revision_digest::text)
     OR v_outbox.payload->>'snapshotBatchId'<>v_source.snapshot_batch_id::text
     OR v_outbox.payload->>'snapshotDigest'<>
        btrim(v_source.snapshot_digest::text)
     OR v_outbox.payload->>'concentrationBand'<>v_source.concentration_band::text
     OR v_outbox.payload->>'entrySetDigest'<>
        btrim(v_source.entry_set_digest::text)
     OR (v_source.revision=1 AND
       v_outbox.payload->'priorRevision'<>'null'::jsonb)
     OR (v_source.revision>1 AND
       (v_outbox.payload->>'priorRevision')::bigint<>v_source.prior_revision)
     OR (v_outbox.payload->>'effectiveAt')::timestamptz<>
        v_source.effective_at
     OR v_outbox.payload->>'receiptDigest'<>btrim(v_source.receipt_digest::text)
     OR v_outbox.occurred_at<>v_source.published_at
     OR p_projection.disclosure_id<>v_source.disclosure_id
     OR p_projection.revision_id<>v_source.id
     OR p_projection.revision<>v_source.revision
     OR p_projection.revision_digest<>v_source.revision_digest
     OR p_projection.snapshot_batch_id<>v_source.snapshot_batch_id
     OR p_projection.snapshot_digest<>v_source.snapshot_digest
     OR p_projection.concentration_band<>v_source.concentration_band
     OR p_projection.entry_set_digest<>v_source.entry_set_digest
     OR p_projection.prior_revision IS DISTINCT FROM v_source.prior_revision
     OR p_projection.effective_at<>v_source.effective_at
     OR p_projection.receipt_digest<>v_source.receipt_digest THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_EVENT_MISMATCH'
      USING ERRCODE='22023';
  END IF;

  SELECT inbox.* INTO v_inbox
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='public-projection-worker'
    AND inbox.event_id=p_projection.event_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_WORK_ITEM_INVALID'
      USING ERRCODE='55000';
  END IF;
  IF v_inbox.processed_at IS NULL THEN
    IF v_inbox.result IS NULL
       OR v_inbox.result<>'DISPATCHED:'||p_projection.job_id::text THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_STALE_FENCE'
        USING ERRCODE='40001';
    END IF;
    v_job_id:=p_projection.job_id;
  ELSIF v_inbox.result='SUCCEEDED' THEN
    v_job_id:=p_projection.job_id;
  ELSE
    RAISE EXCEPTION 'FUNDING_PROJECTION_WORK_ITEM_INVALID'
      USING ERRCODE='55000';
  END IF;

  SELECT job.* INTO v_job
  FROM ops.jobs AS job
  WHERE job.id=v_job_id
    AND job.job_type='EVENT_DELIVERY'
    AND job.queue='projection-worker'
    AND job.dedupe_key='event:'||p_projection.event_id::text||
      ':public-projection-worker'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_STALE_FENCE'
      USING ERRCODE='40001';
  END IF;
  IF jsonb_typeof(v_job.payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_job.payload))<>8
     OR NOT v_job.payload?&ARRAY[
       'consumerId','eventId','eventType','aggregateType','aggregateId',
       'aggregateVersion','occurredAt','payload'
     ]
     OR v_job.payload->>'consumerId'<>'public-projection-worker'
     OR v_job.payload->>'eventId'<>p_projection.event_id::text
     OR v_job.payload->>'eventType'<>v_outbox.event_type
     OR v_job.payload->>'aggregateType'<>v_outbox.aggregate_type
     OR v_job.payload->>'aggregateId'<>v_outbox.aggregate_id
     OR (v_job.payload->>'aggregateVersion')::bigint<>
        v_outbox.aggregate_version
     OR (v_job.payload->>'occurredAt')::timestamptz<>v_outbox.occurred_at
     OR v_job.payload->'payload'<>v_outbox.payload THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_WORK_ITEM_INVALID'
      USING ERRCODE='55000';
  END IF;
  SELECT attempt.* INTO v_attempt
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id=v_job.id AND attempt.attempt=v_job.attempt_count
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_WORK_ITEM_INVALID'
      USING ERRCODE='55000';
  END IF;

  IF v_inbox.processed_at IS NULL THEN
    IF v_job.status<>'RUNNING' OR v_job.lease_owner IS NULL
       OR v_job.lease_token IS NULL OR v_job.lease_expires_at<=clock_timestamp()
       OR v_job.fencing_token<1 OR v_job.attempt_count<1
       OR v_job.lease_token IS DISTINCT FROM p_projection.job_lease_token
       OR v_job.fencing_token IS DISTINCT FROM
          p_projection.job_fencing_token
       OR v_attempt.finished_at IS NOT NULL
       OR v_attempt.worker_id<>v_job.lease_owner
       OR v_attempt.fencing_token<>v_job.fencing_token THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_STALE_FENCE'
        USING ERRCODE='40001';
    END IF;
  ELSIF v_job.status<>'SUCCEEDED' OR v_job.completed_at IS NULL
     OR v_job.lease_owner IS NOT NULL OR v_job.lease_token IS NOT NULL
     OR v_job.lease_expires_at IS NOT NULL
     OR v_job.last_error_code IS NOT NULL OR v_job.last_error_detail IS NOT NULL
     OR v_attempt.finished_at IS NULL OR v_attempt.outcome<>'SUCCEEDED'
     OR v_attempt.error_code IS NOT NULL OR v_attempt.error_detail IS NOT NULL THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_RECEIPT_CORRUPT'
      USING ERRCODE='55000';
  END IF;
  IF v_inbox.processed_at IS NOT NULL AND (
    v_attempt.fencing_token IS DISTINCT FROM p_projection.job_fencing_token
    OR jsonb_typeof(v_attempt.metrics)<>'object'
    OR v_attempt.metrics->>'jobId'<>p_projection.job_id::text
    OR v_attempt.metrics->>'jobFencingToken'<>
       p_projection.job_fencing_token::text
    OR v_attempt.metrics->>'jobLeaseTokenDigest'<>
       btrim(v_job_lease_token_digest::text)
  ) THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_STALE_FENCE'
      USING ERRCODE='40001';
  END IF;

  SELECT report.* INTO v_report
  FROM public.transparency_reports AS report
  WHERE report.source_revision_id=v_source.id
  FOR SHARE;
  v_existing_report:=FOUND;
  IF v_source.revision=1 THEN
    IF v_source.prior_revision_id IS NOT NULL
       OR v_source.prior_revision_digest IS NOT NULL THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_SOURCE_UNAVAILABLE'
        USING ERRCODE='55000';
    END IF;
    v_prior_report_id:=NULL;
  ELSE
    SELECT report.* INTO v_prior_report
    FROM public.transparency_reports AS report
    WHERE report.source_revision_id=v_source.prior_revision_id
      AND report.report_kind='FUNDING_DISCLOSURE'
    FOR SHARE;
    IF NOT FOUND
       OR v_prior_report.source_disclosure_id<>v_source.disclosure_id
       OR v_prior_report.source_revision<>v_source.prior_revision
       OR v_prior_report.source_revision_digest<>v_source.prior_revision_digest THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_HEAD_MISMATCH'
        USING ERRCODE='40001';
    END IF;
    v_prior_report_id:=v_prior_report.id;
  END IF;

  IF NOT v_existing_report THEN
    SELECT report.* INTO v_head_report
    FROM public.transparency_reports AS report
    WHERE report.report_kind='FUNDING_DISCLOSURE'
      AND report.source_disclosure_id=v_source.disclosure_id
    ORDER BY report.source_revision DESC,report.id DESC
    LIMIT 1
    FOR SHARE;
    IF (v_source.revision=1 AND FOUND)
       OR (v_source.revision>1 AND (
         NOT FOUND OR v_head_report.id<>v_prior_report_id
       )) THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_HEAD_MISMATCH'
        USING ERRCODE='40001';
    END IF;
  END IF;

  v_effective_at_text:=v_outbox.payload->>'effectiveAt';
  v_published_at_text:=v_job.payload->>'occurredAt';
  v_title:=v_source.fiscal_year::text||'년 '
    ||v_source.fiscal_quarter::text||'분기 재원 공개';
  IF v_existing_report THEN
    v_report_id:=v_report.id;
    v_completed_at:=v_report.projected_at;
    v_report_json:=v_report.report;
    IF v_report.report_kind<>'FUNDING_DISCLOSURE'
       OR v_report.source_revision_id<>v_source.id
       OR v_report.source_disclosure_id<>v_source.disclosure_id
       OR v_report.source_revision<>v_source.revision
       OR v_report.source_revision_digest<>v_source.revision_digest
       OR v_report.supersedes_report_id IS DISTINCT FROM v_prior_report_id
       OR v_report.report_schema_version<>1
       OR v_report.period_start<>v_source.period_start
       OR v_report.period_end<>v_source.period_end
       OR v_report.title<>v_title OR v_report.summary<>v_summary
       OR v_report.published_at<>v_source.published_at
       OR v_report.projected_at IS NULL
       OR jsonb_typeof(v_report_json)<>'object' THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_REPLAY_CONFLICT'
        USING ERRCODE='23505';
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(v_report_json))<>19
       OR NOT v_report_json?&ARRAY[
         'schemaVersion','disclosureId','revision','fiscalYear','fiscalQuarter',
         'periodStart','periodEnd','reportingCurrency','concentrationBand',
         'caveat','purpose','policyRequests','sources','entries','effectiveAt',
         'publishedAt','supersedesRevision','sourceRevisionDigest',
         'publicContentDigest'
       ]
       OR v_report_json->'schemaVersion' IS DISTINCT FROM to_jsonb(1)
       OR v_report_json->>'disclosureId' IS DISTINCT FROM
          v_source.disclosure_id::text
       OR v_report_json->'revision' IS DISTINCT FROM to_jsonb(v_source.revision)
       OR v_report_json->'fiscalYear' IS DISTINCT FROM
          to_jsonb(v_source.fiscal_year)
       OR v_report_json->'fiscalQuarter' IS DISTINCT FROM
          to_jsonb(v_source.fiscal_quarter)
       OR v_report_json->>'periodStart' IS DISTINCT FROM
          v_source.period_start::text
       OR v_report_json->>'periodEnd' IS DISTINCT FROM v_source.period_end::text
       OR v_report_json->>'reportingCurrency' IS DISTINCT FROM
          btrim(v_source.reporting_currency::text)
       OR v_report_json->>'concentrationBand' IS DISTINCT FROM
          v_source.concentration_band::text
       OR v_report_json->>'caveat' IS DISTINCT FROM v_source.public_caveat_text
       OR v_report_json->>'purpose' IS DISTINCT FROM v_source.purpose
       OR v_report_json->>'effectiveAt' IS DISTINCT FROM v_effective_at_text
       OR v_report_json->>'publishedAt' IS DISTINCT FROM v_published_at_text
       OR (v_source.prior_revision IS NULL
         AND v_report_json->'supersedesRevision'<>'null'::jsonb)
       OR (v_source.prior_revision IS NOT NULL
         AND v_report_json->'supersedesRevision' IS DISTINCT FROM
           to_jsonb(v_source.prior_revision))
       OR v_report_json->>'sourceRevisionDigest' IS DISTINCT FROM
          btrim(v_source.revision_digest::text)
       OR v_report_json->>'publicContentDigest' IS DISTINCT FROM
          btrim(v_source.public_content_digest::text) THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_REPLAY_CONFLICT'
        USING ERRCODE='23505';
    END IF;
    IF jsonb_typeof(v_report_json->'policyRequests')<>'object'
       OR jsonb_typeof(v_report_json->'sources')<>'array'
       OR jsonb_typeof(v_report_json->'entries')<>'array' THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_REPLAY_CONFLICT'
        USING ERRCODE='23505';
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(
         v_report_json->'policyRequests'
       ))<>7
       OR NOT (v_report_json->'policyRequests')?&ARRAY[
         'total','accepted','partiallyAccepted','rejected','withdrawn','pending',
         'outcomeDigest'
       ]
       OR v_report_json->'policyRequests'->'total' IS DISTINCT FROM
          to_jsonb(v_source.policy_request_total)
       OR v_report_json->'policyRequests'->'accepted' IS DISTINCT FROM
          to_jsonb(v_source.policy_request_accepted)
       OR v_report_json->'policyRequests'->'partiallyAccepted' IS DISTINCT FROM
          to_jsonb(v_source.policy_request_partially_accepted)
       OR v_report_json->'policyRequests'->'rejected' IS DISTINCT FROM
          to_jsonb(v_source.policy_request_rejected)
       OR v_report_json->'policyRequests'->'withdrawn' IS DISTINCT FROM
          to_jsonb(v_source.policy_request_withdrawn)
       OR v_report_json->'policyRequests'->'pending' IS DISTINCT FROM
          to_jsonb(v_source.policy_request_pending)
       OR v_report_json->'policyRequests'->>'outcomeDigest' IS DISTINCT FROM
          btrim(v_source.policy_request_outcome_digest::text)
       OR jsonb_array_length(v_report_json->'entries')<>v_source.entry_count THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_REPLAY_CONFLICT'
        USING ERRCODE='23505';
    END IF;
    v_projection_preimage:=jsonb_build_object(
      'reportKind',v_report.report_kind,
      'sourceRevisionId',v_report.source_revision_id,
      'sourceDisclosureId',v_report.source_disclosure_id,
      'sourceRevision',v_report.source_revision,
      'sourceRevisionDigest',btrim(v_report.source_revision_digest::text),
      'periodStart',v_report.period_start::text,
      'periodEnd',v_report.period_end::text,
      'title',v_report.title,'summary',v_report.summary,
      'report',v_report_json,'publishedAt',v_published_at_text,
      'supersedesReportId',v_report.supersedes_report_id
    );
    v_projection_digest:=encode(extensions.digest(
      ops.canonical_jsonb_v1(v_projection_preimage),'sha256'
    ),'hex');
    IF v_report.projection_digest<>v_projection_digest THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_REPLAY_CONFLICT'
        USING ERRCODE='23505';
    END IF;
  ELSE
    FOR v_public_input IN
      SELECT * FROM editorial.read_public_funding_projection_inputs_v1(
        v_source.id,v_source.revision_digest
      )
    LOOP
      v_public_input_count:=v_public_input_count+1;
    END LOOP;
    IF v_public_input_count<>1
       OR (v_public_input.revision).disclosure_id<>v_source.disclosure_id
       OR (v_public_input.revision).revision<>v_source.revision
       OR (v_public_input.revision).revision_digest<>v_source.revision_digest
       OR (v_public_input.revision).entry_set_digest<>v_source.entry_set_digest
       OR (v_public_input.revision).effective_at<>v_source.effective_at
       OR (v_public_input.revision).published_at<>v_source.published_at THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_SOURCE_UNAVAILABLE'
        USING ERRCODE='55000';
    END IF;

  FOREACH v_public_entry IN ARRAY v_public_input.entries
  LOOP
    v_sources:=v_sources||v_public_entry.public_source_links;
    v_report_entries:=v_report_entries||jsonb_build_array(jsonb_build_object(
      'ordinal',v_public_entry.ordinal,
      'identityDisclosureMode',v_public_entry.identity_disclosure_mode::text,
      'publicDisplayName',v_public_entry.public_display_name,
      'withholdingPublicExplanation',
        v_public_entry.withholding_public_explanation,
      'counterpartyCategory',v_public_entry.counterparty_category,
      'fundingSourceKind',v_public_entry.funding_source_kind::text,
      'amountBandLower',v_public_entry.amount_band_lower::text,
      'amountBandUpper',v_public_entry.amount_band_upper::text,
      'reportingCurrency',btrim(v_public_entry.reporting_currency::text),
      'concentrationBand',v_public_entry.concentration_band::text,
      'denominatorUnknownReason',
        v_public_entry.denominator_unknown_reason::text,
      'groupingDisputeReason',v_public_entry.grouping_dispute_reason::text,
      'concentrationUnknownReason',
        v_public_entry.concentration_unknown_reason::text,
      'publicCaveatText',v_public_entry.public_caveat_text,
      'purpose',v_public_entry.purpose,
      'conflictDisclosure',v_public_entry.conflict_disclosure,
      'mitigationSummary',v_public_entry.mitigation_summary,
      'governmentRelated',v_public_entry.government_related,
      'politicalPartyRelated',v_public_entry.political_party_related,
      'procurementSupplierRelated',
        v_public_entry.procurement_supplier_related,
      'investigatedSubjectRelated',
        v_public_entry.investigated_subject_related,
      'relatedParty',v_public_entry.related_party,
      'publicCaseRefs',to_jsonb(v_public_entry.public_case_refs),
      'publicSourceLinks',to_jsonb(v_public_entry.public_source_links),
      'entryDigest',btrim(v_public_entry.entry_digest::text)
    ));
  END LOOP;
  SELECT COALESCE(array_agg(DISTINCT source_link ORDER BY
    source_link COLLATE "C"),'{}'::text[])
  INTO v_sources
  FROM unnest(v_sources) AS links(source_link);

  v_report_json:=jsonb_build_object(
    'schemaVersion',1,
    'disclosureId',(v_public_input.revision).disclosure_id,
    'revision',(v_public_input.revision).revision,
    'fiscalYear',(v_public_input.revision).fiscal_year,
    'fiscalQuarter',(v_public_input.revision).fiscal_quarter,
    'periodStart',(v_public_input.revision).period_start::text,
    'periodEnd',(v_public_input.revision).period_end::text,
    'reportingCurrency',btrim((v_public_input.revision).reporting_currency::text),
    'concentrationBand',(v_public_input.revision).concentration_band::text,
    'caveat',(v_public_input.revision).public_caveat_text,
    'purpose',(v_public_input.revision).purpose,
    'policyRequests',jsonb_build_object(
      'total',(v_public_input.revision).policy_request_total,
      'accepted',(v_public_input.revision).policy_request_accepted,
      'partiallyAccepted',
        (v_public_input.revision).policy_request_partially_accepted,
      'rejected',(v_public_input.revision).policy_request_rejected,
      'withdrawn',(v_public_input.revision).policy_request_withdrawn,
      'pending',(v_public_input.revision).policy_request_pending,
      'outcomeDigest',btrim(
        (v_public_input.revision).policy_request_outcome_digest::text
      )
    ),
    'sources',to_jsonb(v_sources),
    'entries',v_report_entries,
    'effectiveAt',v_effective_at_text,
    'publishedAt',v_published_at_text,
    'supersedesRevision',(v_public_input.revision).prior_revision,
    'sourceRevisionDigest',btrim(v_source.revision_digest::text),
    'publicContentDigest',btrim(
      (v_public_input.revision).public_content_digest::text
    )
  );
  v_projection_preimage:=jsonb_build_object(
    'reportKind','FUNDING_DISCLOSURE',
    'sourceRevisionId',v_source.id,
    'sourceDisclosureId',v_source.disclosure_id,
    'sourceRevision',v_source.revision,
    'sourceRevisionDigest',btrim(v_source.revision_digest::text),
    'periodStart',(v_public_input.revision).period_start::text,
    'periodEnd',(v_public_input.revision).period_end::text,
    'title',v_title,'summary',v_summary,'report',v_report_json,
    'publishedAt',v_published_at_text,
    'supersedesReportId',v_prior_report_id
  );
  v_projection_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_projection_preimage),'sha256'
  ),'hex');

    v_report_id:=gen_random_uuid();
    v_completed_at:=clock_timestamp();
    INSERT INTO public.transparency_reports(
      id,period_start,period_end,title,summary,report,published_at,
      report_kind,source_revision_id,source_disclosure_id,source_revision,
      source_revision_digest,supersedes_report_id,report_schema_version,
      projection_digest,projected_at
    ) VALUES (
      v_report_id,(v_public_input.revision).period_start,
      (v_public_input.revision).period_end,v_title,v_summary,v_report_json,
      v_source.published_at,'FUNDING_DISCLOSURE',v_source.id,
      v_source.disclosure_id,v_source.revision,v_source.revision_digest,
      v_prior_report_id,1,v_projection_digest,v_completed_at
    );
  END IF;

  v_inbox_preimage:=jsonb_build_object(
    'schemaVersion','funding-projection-inbox-receipt.v2',
    'consumerId','public-projection-worker','eventId',p_projection.event_id,
    'receivedAt',v_inbox.received_at,
    'processedAt',COALESCE(v_inbox.processed_at,v_completed_at),
    'result','SUCCEEDED'
  );
  v_inbox_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_inbox_preimage),'sha256'
  ),'hex');
  v_job_payload_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_job.payload),'sha256'
  ),'hex');
  v_job_preimage:=jsonb_build_object(
    'schemaVersion','funding-projection-job-receipt.v2',
    'jobId',v_job.id,'jobType',v_job.job_type,'queue',v_job.queue,
    'payloadDigest',btrim(v_job_payload_digest::text),
    'attemptId',v_attempt.id,'attempt',v_attempt.attempt,
    'workerId',v_attempt.worker_id,'fencingToken',v_attempt.fencing_token,
    'leaseTokenDigest',btrim(v_job_lease_token_digest::text),
    'startedAt',v_attempt.started_at,
    'finishedAt',COALESCE(v_attempt.finished_at,v_completed_at),
    'outcome','SUCCEEDED','status','SUCCEEDED',
    'version',CASE WHEN v_existing_report THEN v_job.version
      ELSE v_job.version+1 END
  );
  v_job_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_job_preimage),'sha256'
  ),'hex');
  v_audit_details:=jsonb_build_object(
    'operationId',v_operation_id,'eventId',p_projection.event_id,
    'jobId',p_projection.job_id,
    'jobFencingToken',p_projection.job_fencing_token,
    'jobLeaseTokenDigest',btrim(v_job_lease_token_digest::text),
    'sourceRevisionId',v_source.id,'sourceDisclosureId',v_source.disclosure_id,
    'sourceRevision',v_source.revision,
    'sourceRevisionDigest',btrim(v_source.revision_digest::text),
    'projectionId',v_report_id,
    'projectionDigest',btrim(v_projection_digest::text),
    'projectedRowCount',1
  );

  IF v_existing_report THEN
    IF jsonb_typeof(v_attempt.metrics)<>'object'
       OR NOT v_attempt.metrics?&ARRAY[
         'jobId','jobFencingToken','jobLeaseTokenDigest',
         'operationId','projectionId','projectionVersion','projectionDigest',
         'projectedRowCount','inboxReceiptDigest','jobReceiptDigest',
         'auditEventId','receiptDigest'
       ]
       OR (SELECT count(*) FROM jsonb_object_keys(v_attempt.metrics))<>12
       OR v_attempt.metrics->>'operationId'<>v_operation_id
       OR (v_attempt.metrics->>'projectionId')::uuid<>v_report_id
       OR (v_attempt.metrics->>'projectionVersion')::bigint<>v_source.revision
       OR v_attempt.metrics->>'projectionDigest'<>
          btrim(v_projection_digest::text)
       OR (v_attempt.metrics->>'projectedRowCount')::bigint<>1
       OR v_attempt.metrics->>'inboxReceiptDigest'<>
          btrim(v_inbox_receipt_digest::text)
       OR v_attempt.metrics->>'jobReceiptDigest'<>
          btrim(v_job_receipt_digest::text) THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_RECEIPT_CORRUPT'
        USING ERRCODE='55000';
    END IF;
    v_audit_event_id:=(v_attempt.metrics->>'auditEventId')::uuid;
    SELECT audit.* INTO v_audit
    FROM ops.audit_events AS audit
    WHERE audit.id=v_audit_event_id
    FOR SHARE;
    IF NOT FOUND OR v_audit.request_id<>p_projection.event_id
       OR v_audit.actor_type<>'SERVICE'
       OR v_audit.actor_id<>'public-projection-worker'
       OR v_audit.action<>'FUNDING_DISCLOSURE_PROJECTED'
       OR v_audit.object_type<>'TRANSPARENCY_REPORT'
       OR v_audit.object_id<>v_report_id::text
       OR v_audit.outcome<>'SUCCESS'
       OR v_audit.details<>v_audit_details THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_RECEIPT_CORRUPT'
        USING ERRCODE='55000';
    END IF;
  ELSE
    v_audit_event_id:=ops.append_audit_event(
      'public-projection:funding-disclosure','SERVICE',
      'public-projection-worker',NULL,'FUNDING_DISCLOSURE_PROJECTED',
      'TRANSPARENCY_REPORT',v_report_id::text,NULL,'SUCCESS',
      'APPROVED_FUNDING_DISCLOSURE',p_projection.event_id,v_audit_details
    );
  END IF;

  v_receipt_preimage:=jsonb_build_object(
    'schemaVersion','funding-projection-mutation-receipt.v2',
    'operationId',v_operation_id,'eventId',p_projection.event_id,
    'sourceAggregateId',v_source.id,
    'sourceAggregateVersion',v_source.revision,
    'sourceAggregateDigest',btrim(v_source.revision_digest::text),
    'projectionId',v_report_id,'projectionVersion',v_source.revision,
    'projectionDigest',btrim(v_projection_digest::text),
    'projectedRowCount',1,
    'inboxReceiptDigest',btrim(v_inbox_receipt_digest::text),
    'jobReceiptDigest',btrim(v_job_receipt_digest::text),
    'auditEventId',v_audit_event_id,'outboxEventIds','[]'::jsonb,
    'completedAt',v_completed_at
  );
  v_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_receipt_preimage),'sha256'
  ),'hex');
  v_metrics:=jsonb_build_object(
    'jobId',p_projection.job_id,
    'jobFencingToken',p_projection.job_fencing_token,
    'jobLeaseTokenDigest',btrim(v_job_lease_token_digest::text),
    'operationId',v_operation_id,'projectionId',v_report_id,
    'projectionVersion',v_source.revision,
    'projectionDigest',btrim(v_projection_digest::text),
    'projectedRowCount',1,
    'inboxReceiptDigest',btrim(v_inbox_receipt_digest::text),
    'jobReceiptDigest',btrim(v_job_receipt_digest::text),
    'auditEventId',v_audit_event_id,
    'receiptDigest',btrim(v_receipt_digest::text)
  );

  IF v_existing_report THEN
    IF v_attempt.metrics<>v_metrics
       OR v_attempt.metrics->>'receiptDigest'<>
          btrim(v_receipt_digest::text)
       OR v_inbox.processed_at<>v_completed_at
       OR v_job.completed_at<>v_completed_at
       OR v_attempt.finished_at<>v_completed_at THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_RECEIPT_CORRUPT'
        USING ERRCODE='55000';
    END IF;
  ELSE
    UPDATE ops.inbox
    SET processed_at=v_completed_at,result='SUCCEEDED'
    WHERE consumer='public-projection-worker'
      AND event_id=p_projection.event_id
      AND processed_at IS NULL
      AND result='DISPATCHED:'||v_job.id::text;
    GET DIAGNOSTICS v_changed=ROW_COUNT;
    IF v_changed<>1 THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_STALE_FENCE'
        USING ERRCODE='40001';
    END IF;
    UPDATE ops.jobs
    SET status='SUCCEEDED',completed_at=v_completed_at,
        lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
        version=version+1,last_error_code=NULL,last_error_detail=NULL
    WHERE id=p_projection.job_id AND status='RUNNING'
      AND lease_owner=v_attempt.worker_id
      AND lease_token=p_projection.job_lease_token
      AND fencing_token=p_projection.job_fencing_token
      AND lease_expires_at>clock_timestamp();
    GET DIAGNOSTICS v_changed=ROW_COUNT;
    IF v_changed<>1 THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_STALE_FENCE'
        USING ERRCODE='40001';
    END IF;
    UPDATE ops.job_attempts
    SET finished_at=v_completed_at,outcome='SUCCEEDED',
        error_code=NULL,error_detail=NULL,metrics=v_metrics
    WHERE id=v_attempt.id AND job_id=v_job.id
      AND attempt=v_job.attempt_count
      AND worker_id=v_attempt.worker_id
      AND fencing_token=p_projection.job_fencing_token
      AND finished_at IS NULL;
    GET DIAGNOSTICS v_changed=ROW_COUNT;
    IF v_changed<>1 THEN
      RAISE EXCEPTION 'FUNDING_PROJECTION_STALE_FENCE'
        USING ERRCODE='40001';
    END IF;
  END IF;

  v_receipt:=ROW(
    v_operation_id,p_projection.event_id,v_source.id,v_source.revision,
    v_source.revision_digest,v_report_id,v_source.revision,
    v_projection_digest,1,v_inbox_receipt_digest,v_job_receipt_digest,
    v_audit_event_id,ARRAY[]::uuid[],v_receipt_digest,v_completed_at
  )::public.projection_mutation_receipt_v2;
  RETURN v_receipt;
EXCEPTION
  WHEN invalid_text_representation OR invalid_datetime_format
       OR datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'FUNDING_PROJECTION_SOURCE_INVALID'
      USING ERRCODE='55000';
END
$r6e_public_funding_projector$;
ALTER FUNCTION public.project_funding_disclosure_revision_v2(
  public.funding_disclosure_projection_v2
) OWNER TO gurine_migrator;

-- The SECURITY DEFINER owner is NOLOGIN and receives only the base-relation
-- privileges required to insert one public revision and atomically terminalize
-- its exact inbox/job attempt.  This grants no new privilege to a runtime role,
-- and direct runtime DML on the public projection remains closed.
GRANT SELECT,INSERT ON public.transparency_reports TO gurine_migrator;
GRANT SELECT ON ops.inbox,ops.jobs,ops.job_attempts TO gurine_migrator;
GRANT UPDATE(processed_at,result) ON ops.inbox TO gurine_migrator;
GRANT UPDATE(
  status,completed_at,lease_owner,lease_token,lease_expires_at,version,
  last_error_code,last_error_detail
) ON ops.jobs TO gurine_migrator;
GRANT UPDATE(
  finished_at,outcome,error_code,error_detail,metrics
) ON ops.job_attempts TO gurine_migrator;

REVOKE ALL ON FUNCTION editorial.read_public_funding_projection_inputs_v1(
  uuid,char(64)
) FROM PUBLIC,gurine_public_projector,gurine_public_api,
  gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_notification_worker,gurine_submission_api,gurine_ingest_worker,
  gurine_scheduler,gurine_document_extractor,gurine_identity_api,
  gurine_auditor,gurine_billing_gateway,gurine_economics_importer;
REVOKE ALL ON FUNCTION public.project_funding_disclosure_revision_v2(
  public.funding_disclosure_projection_v2
) FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_scheduler,gurine_document_extractor,
  gurine_identity_api,gurine_auditor,gurine_billing_gateway,
  gurine_economics_importer;
GRANT EXECUTE ON FUNCTION public.project_funding_disclosure_revision_v2(
  public.funding_disclosure_projection_v2
) TO gurine_public_projector;

GRANT USAGE ON TYPE editorial.funding_public_revision_v1,
  editorial.funding_public_entry_v1,
  editorial.funding_public_projection_input_v1,
  editorial.funding_concentration_band,
  public.funding_disclosure_projection_v2,
  public.projection_mutation_receipt_v2
TO gurine_public_projector;
REVOKE ALL ON public.transparency_reports FROM PUBLIC,
  gurine_public_projector,gurine_public_api,gurine_control_api,
  gurine_workflow_worker,gurine_analysis_worker,gurine_notification_worker,
  gurine_submission_api,gurine_ingest_worker,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_billing_gateway,gurine_economics_importer;
GRANT SELECT ON public.transparency_reports TO gurine_public_api;

-- R6E_FUNDING_DISCLOSURE_LIFECYCLE_GUARD_FINAL
-- GFD-AUTHORITY-V1 approves the governance shape but leaves the publisher
-- implementation unavailable. Guard all six existing lifecycle operations in
-- the final dispatcher before they can enter either the strict HYPOTHESIS path
-- or the legacy 0030 mutator. This wrapper changes no function ABI.
CREATE OR REPLACE FUNCTION ops.execute_action_approval_v1(
  p_operation text,
  p_request jsonb,
  p_actor uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $r6e_funding_disclosure_lifecycle_guard$
DECLARE
  v_proposal_id uuid;
  v_action_kind text;
  v_draft_kind text;
  v_legacy_kind text;
  v_origin_kind text;
  v_proposal_contract_version smallint;
BEGIN
  IF session_user IS DISTINCT FROM 'gurine_control_api'
     OR current_user IS DISTINCT FROM 'gurine_migrator' THEN
    RAISE EXCEPTION 'ACTION_APPROVAL_CALLER_FORBIDDEN'
      USING ERRCODE='42501';
  END IF;
  IF p_operation NOT IN (
    'createActionProposal','updateActionDraft','previewActionDraft',
    'submitActionForReview','claimActionReview','submitActionDecision'
  ) OR p_request IS NULL OR jsonb_typeof(p_request)<>'object' THEN
    RETURN ops.execute_action_approval_v1_legacy_0030(
      p_operation,p_request,p_actor
    );
  END IF;

  v_draft_kind:=p_request#>>'{draft,kind}';
  v_legacy_kind:=p_request#>>'{draft,actionKind}';
  IF v_legacy_kind='FUNDING_DISCLOSURE' THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_AUTHORITY_UNAVAILABLE'
      USING ERRCODE='55000';
  END IF;

  IF p_operation='createActionProposal' THEN
    IF p_request->>'actionKind'='FUNDING_DISCLOSURE'
       OR v_draft_kind='FUNDING_DISCLOSURE' THEN
      RAISE EXCEPTION 'FUNDING_DISCLOSURE_AUTHORITY_UNAVAILABLE'
        USING ERRCODE='55000';
    END IF;
    RETURN ops.execute_action_approval_v1_legacy_0030(
      p_operation,p_request,p_actor
    );
  END IF;

  IF p_operation='updateActionDraft'
     AND v_draft_kind='FUNDING_DISCLOSURE' THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_AUTHORITY_UNAVAILABLE'
      USING ERRCODE='55000';
  END IF;

  v_proposal_id:=NULLIF(p_request->>'proposalId','')::uuid;
  IF v_proposal_id IS NOT NULL THEN
    SELECT proposal.action_kind,proposal.origin_kind,
           suggestion.proposal_contract_version
      INTO v_action_kind,v_origin_kind,v_proposal_contract_version
    FROM ops.action_proposals AS proposal
    LEFT JOIN ops.agent_suggestions AS suggestion
      ON suggestion.id=proposal.origin_id
    WHERE proposal.id=v_proposal_id
    FOR SHARE OF proposal;

    IF v_action_kind='FUNDING_DISCLOSURE' THEN
      RAISE EXCEPTION 'FUNDING_DISCLOSURE_AUTHORITY_UNAVAILABLE'
        USING ERRCODE='55000';
    END IF;

    IF p_operation IN (
         'previewActionDraft','submitActionForReview','submitActionDecision'
       )
       AND v_action_kind='HYPOTHESIS'
       AND v_origin_kind='AGENT_PROPOSAL'
       AND v_proposal_contract_version=2 THEN
      IF p_operation='previewActionDraft' THEN
        RETURN ops.preview_accepted_hypothesis_action_draft_v2(
          p_request,p_actor
        );
      ELSIF p_operation='submitActionForReview' THEN
        RETURN ops.submit_accepted_hypothesis_action_for_review_v2(
          p_request,p_actor
        );
      END IF;
      RETURN ops.execute_accepted_hypothesis_action_decision_v2(
        p_request,p_actor
      );
    END IF;
  END IF;

  RETURN ops.execute_action_approval_v1_legacy_0030(
    p_operation,p_request,p_actor
  );
END
$r6e_funding_disclosure_lifecycle_guard$;
ALTER FUNCTION ops.execute_action_approval_v1(text,jsonb,uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.execute_action_approval_v1(text,jsonb,uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.execute_action_approval_v1(text,jsonb,uuid)
  TO gurine_control_api;

-- R6E_PAYMENT_OWNER_ACL_FINAL
-- Payment mutations execute under the NOLOGIN gurine_migrator owner. LOGIN
-- principals get only the closed composite ABI below; the compatibility
-- writer roles remain inert and no runtime role receives payment-table DML.
ALTER FUNCTION ops.r6e_payment_sha256_jsonb_v1(jsonb)
  OWNER TO gurine_migrator;
ALTER FUNCTION ops.r6e_test_donation_tier_amount_v1(uuid,char(64),uuid)
  OWNER TO gurine_migrator;
ALTER FUNCTION ops.create_r6e_payment_review_task_core_v1(
  ops.r6e_payment_review_task_create_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.create_r6e_payment_review_task_v1(
  ops.r6e_payment_review_task_create_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.claim_r6e_donation_intent_v1(
  ops.r6e_donation_intent_claim_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.complete_r6e_payment_method_binding_v1(
  ops.r6e_payment_method_binding_complete_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.fail_r6e_donation_intent_v1(
  ops.r6e_donation_intent_fail_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.apply_r6e_payment_observation_v1(
  uuid,ops.r6e_payment_observation_v1,char(64)
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.complete_r6e_donation_charge_v1(
  ops.r6e_donation_charge_complete_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.materialize_payment_review_notification_v1(
  ops.payment_review_notification_materialize_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.claim_r6e_provider_webhook_v1(
  ops.r6e_provider_webhook_claim_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.release_r6e_provider_webhook_claim_v1(
  ops.r6e_provider_webhook_release_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.r6e_donation_intent_request_digest_v1(
  ops.r6e_donation_intent_claim_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.r6e_payment_binding_completion_digest_v1(
  ops.r6e_payment_method_binding_complete_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.r6e_payment_intent_failure_digest_v1(
  ops.r6e_donation_intent_fail_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.r6e_payment_observation_completion_digest_v1(
  uuid,char(64),ops.r6e_payment_observation_v1,text
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.r6e_provider_webhook_claim_digest_v1(
  ops.r6e_provider_webhook_claim_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.r6e_provider_webhook_completion_digest_v1(
  ops.r6e_provider_webhook_complete_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.r6e_provider_webhook_release_digest_v1(
  ops.r6e_provider_webhook_release_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.complete_r6e_provider_webhook_v1(
  ops.r6e_provider_webhook_complete_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.claim_r6e_donation_charge_job_v1(
  ops.r6e_donation_charge_job_claim_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.claim_r6e_donation_charge_v1(
  ops.r6e_donation_charge_claim_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.accept_r6e_donation_charge_v1(
  ops.r6e_donation_charge_accept_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.fail_r6e_donation_charge_v1(
  ops.r6e_donation_charge_fail_v1
) OWNER TO gurine_migrator;
ALTER FUNCTION ops.require_r6e_charge_reconciliation_v1(
  ops.r6e_charge_reconciliation_v1
) OWNER TO gurine_migrator;

-- Internal payment helpers remain executable only by their owner.  The two
-- migrator-owned closed readers are the sole cross-owner helper calls.
REVOKE ALL ON FUNCTION
  ops.r6e_payment_sha256_jsonb_v1(jsonb),
  ops.r6e_test_donation_tier_amount_v1(uuid,char(64),uuid),
  ops.create_r6e_payment_review_task_v1(
    ops.r6e_payment_review_task_create_v1
  ),
  ops.apply_r6e_payment_observation_v1(
    uuid,ops.r6e_payment_observation_v1,char(64)
  ),
  ops.r6e_donation_intent_request_digest_v1(
    ops.r6e_donation_intent_claim_v1
  ),
  ops.r6e_payment_binding_completion_digest_v1(
    ops.r6e_payment_method_binding_complete_v1
  ),
  ops.r6e_payment_intent_failure_digest_v1(
    ops.r6e_donation_intent_fail_v1
  ),
  ops.r6e_payment_observation_completion_digest_v1(
    uuid,char(64),ops.r6e_payment_observation_v1,text
  ),
  ops.r6e_provider_webhook_claim_digest_v1(
    ops.r6e_provider_webhook_claim_v1
  ),
  ops.r6e_provider_webhook_completion_digest_v1(
    ops.r6e_provider_webhook_complete_v1
  ),
  ops.r6e_provider_webhook_release_digest_v1(
    ops.r6e_provider_webhook_release_v1
  )
FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_public_projector,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_billing_gateway,gurine_economics_importer,
  gurine_economics_writer,gurine_egress_gateway;

REVOKE ALL ON FUNCTION
  ops.resolve_r6e_payment_review_authority_v1(uuid),
  ops.r6e_payment_review_source_is_authoritative_v1(text,uuid,char(64))
FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_public_projector,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_billing_gateway,gurine_economics_importer,
  gurine_economics_writer,gurine_egress_gateway,gurine_payment_writer;

-- The migrator-owned economics path may create the independently approved
-- collection-failure review effect, but no LOGIN role can call this internal
-- function directly.
REVOKE ALL ON FUNCTION ops.create_r6e_payment_review_task_core_v1(
  ops.r6e_payment_review_task_create_v1
) FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_public_projector,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_billing_gateway,gurine_economics_importer,
  gurine_economics_writer,gurine_egress_gateway;

-- Exactly twelve payment commands form the billing-gateway ABI.
REVOKE ALL ON FUNCTION
  ops.claim_r6e_donation_intent_v1(ops.r6e_donation_intent_claim_v1),
  ops.complete_r6e_payment_method_binding_v1(
    ops.r6e_payment_method_binding_complete_v1
  ),
  ops.fail_r6e_donation_intent_v1(ops.r6e_donation_intent_fail_v1),
  ops.claim_r6e_donation_charge_job_v1(
    ops.r6e_donation_charge_job_claim_v1
  ),
  ops.claim_r6e_donation_charge_v1(ops.r6e_donation_charge_claim_v1),
  ops.accept_r6e_donation_charge_v1(ops.r6e_donation_charge_accept_v1),
  ops.complete_r6e_donation_charge_v1(
    ops.r6e_donation_charge_complete_v1
  ),
  ops.fail_r6e_donation_charge_v1(ops.r6e_donation_charge_fail_v1),
  ops.require_r6e_charge_reconciliation_v1(
    ops.r6e_charge_reconciliation_v1
  ),
  ops.claim_r6e_provider_webhook_v1(ops.r6e_provider_webhook_claim_v1),
  ops.complete_r6e_provider_webhook_v1(
    ops.r6e_provider_webhook_complete_v1
  ),
  ops.release_r6e_provider_webhook_claim_v1(
    ops.r6e_provider_webhook_release_v1
  )
FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_public_projector,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_billing_gateway,gurine_economics_importer,
  gurine_economics_writer,gurine_egress_gateway;
GRANT EXECUTE ON FUNCTION
  ops.claim_r6e_donation_intent_v1(ops.r6e_donation_intent_claim_v1),
  ops.complete_r6e_payment_method_binding_v1(
    ops.r6e_payment_method_binding_complete_v1
  ),
  ops.fail_r6e_donation_intent_v1(ops.r6e_donation_intent_fail_v1),
  ops.claim_r6e_donation_charge_job_v1(
    ops.r6e_donation_charge_job_claim_v1
  ),
  ops.claim_r6e_donation_charge_v1(ops.r6e_donation_charge_claim_v1),
  ops.accept_r6e_donation_charge_v1(ops.r6e_donation_charge_accept_v1),
  ops.complete_r6e_donation_charge_v1(
    ops.r6e_donation_charge_complete_v1
  ),
  ops.fail_r6e_donation_charge_v1(ops.r6e_donation_charge_fail_v1),
  ops.require_r6e_charge_reconciliation_v1(
    ops.r6e_charge_reconciliation_v1
  ),
  ops.claim_r6e_provider_webhook_v1(ops.r6e_provider_webhook_claim_v1),
  ops.complete_r6e_provider_webhook_v1(
    ops.r6e_provider_webhook_complete_v1
  ),
  ops.release_r6e_provider_webhook_claim_v1(
    ops.r6e_provider_webhook_release_v1
  )
TO gurine_billing_gateway;

REVOKE ALL ON FUNCTION ops.materialize_payment_review_notification_v1(
  ops.payment_review_notification_materialize_v1
) FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_public_projector,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_billing_gateway,gurine_economics_importer,
  gurine_economics_writer,gurine_egress_gateway;
GRANT EXECUTE ON FUNCTION ops.materialize_payment_review_notification_v1(
  ops.payment_review_notification_materialize_v1
) TO gurine_notification_worker;

-- Composite types follow the same caller partition as the functions.  The
-- The gurine_migrator owner has owner-implied type access for nested calls;
-- only the exact runtime callers below receive explicit USAGE.
REVOKE ALL ON TYPE
  ops.r6e_donation_intent_claim_v1,
  ops.r6e_donation_intent_claim_receipt_v1,
  ops.r6e_payment_method_binding_complete_v1,
  ops.r6e_payment_method_binding_receipt_v1,
  ops.r6e_donation_intent_fail_v1,
  ops.r6e_payment_transition_receipt_v1,
  ops.r6e_donation_charge_claim_v1,
  ops.r6e_donation_charge_job_claim_v1,
  ops.r6e_donation_charge_job_claim_receipt_v1,
  ops.r6e_donation_charge_claim_receipt_v1,
  ops.r6e_payment_observation_v1,
  ops.r6e_donation_charge_complete_v1,
  ops.r6e_donation_charge_accept_v1,
  ops.r6e_donation_charge_fail_v1,
  ops.r6e_donation_charge_terminal_receipt_v1,
  ops.r6e_charge_reconciliation_v1,
  ops.r6e_provider_webhook_claim_v1,
  ops.r6e_provider_webhook_claim_receipt_v1,
  ops.r6e_provider_webhook_complete_v1,
  ops.r6e_provider_webhook_receipt_v1,
  ops.r6e_provider_webhook_release_v1,
  ops.r6e_payment_review_task_create_v1,
  ops.r6e_payment_review_task_receipt_v1,
  ops.r6e_payment_review_authority_v1,
  ops.payment_review_notification_materialize_v1,
  ops.payment_review_notification_materialize_receipt_v1
FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_public_projector,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_billing_gateway,gurine_economics_importer,
  gurine_economics_writer,gurine_egress_gateway;
GRANT USAGE ON TYPE
  ops.r6e_donation_intent_claim_v1,
  ops.r6e_donation_intent_claim_receipt_v1,
  ops.r6e_payment_method_binding_complete_v1,
  ops.r6e_payment_method_binding_receipt_v1,
  ops.r6e_donation_intent_fail_v1,
  ops.r6e_payment_transition_receipt_v1,
  ops.r6e_donation_charge_claim_v1,
  ops.r6e_donation_charge_job_claim_v1,
  ops.r6e_donation_charge_job_claim_receipt_v1,
  ops.r6e_donation_charge_claim_receipt_v1,
  ops.r6e_payment_observation_v1,
  ops.r6e_donation_charge_complete_v1,
  ops.r6e_donation_charge_accept_v1,
  ops.r6e_donation_charge_fail_v1,
  ops.r6e_donation_charge_terminal_receipt_v1,
  ops.r6e_charge_reconciliation_v1,
  ops.r6e_provider_webhook_claim_v1,
  ops.r6e_provider_webhook_claim_receipt_v1,
  ops.r6e_provider_webhook_complete_v1,
  ops.r6e_provider_webhook_receipt_v1,
  ops.r6e_provider_webhook_release_v1
TO gurine_billing_gateway;
GRANT USAGE ON TYPE ops.payment_review_notification_materialize_v1,
  ops.payment_review_notification_materialize_receipt_v1
TO gurine_notification_worker;

-- All seven R6e relations are append-only.  INSERT remains possible only from
-- their owner routines; no runtime principal has table DML.
CREATE TRIGGER ops_cash_application_facts_immutable
  BEFORE UPDATE OR DELETE ON ops.cash_application_facts
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER ops_tax_invoice_issuance_receipts_immutable
  BEFORE UPDATE OR DELETE ON ops.tax_invoice_issuance_receipts
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER ops_payment_method_bindings_immutable
  BEFORE UPDATE OR DELETE ON ops.payment_method_bindings
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER ops_payment_charge_attempts_immutable
  BEFORE UPDATE OR DELETE ON ops.payment_charge_attempts
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER ops_provider_webhook_receipts_immutable
  BEFORE UPDATE OR DELETE ON ops.provider_webhook_receipts
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER ops_donation_facts_immutable
  BEFORE UPDATE OR DELETE ON ops.donation_facts
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

REVOKE ALL ON
  ops.cash_application_facts,ops.tax_invoice_issuance_receipts,
  ops.payment_method_bindings,ops.payment_charge_attempts,
  ops.provider_webhook_receipts,ops.donation_facts
FROM PUBLIC,gurine_control_api,gurine_workflow_worker,gurine_analysis_worker,
  gurine_public_projector,gurine_public_api,gurine_submission_api,
  gurine_ingest_worker,gurine_notification_worker,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_billing_gateway;
GRANT SELECT ON
  ops.cash_application_facts,ops.tax_invoice_issuance_receipts,
  ops.payment_method_bindings,ops.payment_charge_attempts,
  ops.provider_webhook_receipts,ops.donation_facts
TO gurine_auditor;
GRANT SELECT ON ops.product_events TO gurine_auditor;

-- Revoke every final-state 0030 writer that accepted a complete caller JSON
-- row without a proposal/decision/execution-authorization binding.  The
-- routines remain private helpers until all callers migrate, but no runtime
-- role can invoke them directly.
REVOKE EXECUTE ON FUNCTION
  ops.record_commercial_qualification_receipt_v1(
    ops.commercial_qualification_receipt_input_v1,text
  ) FROM gurine_workflow_worker;
REVOKE EXECUTE ON FUNCTION
  ops.record_revenue_fact_v1(jsonb,uuid,char(64)),
  ops.record_invoice_fact_v1(jsonb),
  ops.record_invoice_line_fact_v1(jsonb),
  ops.record_usage_fact_v1(jsonb),
  ops.record_invoice_usage_membership_v1(jsonb),
  ops.record_accounting_correction_v1(jsonb),
  ops.record_outcome_fact_v1(jsonb),
  ops.record_paid_evidence_packet_v1(jsonb)
FROM gurine_workflow_worker;

-- This owner-invoker oracle is the stable startup latch for the four
-- externally provisioned R6e roles.  It set-compares every direct privilege
-- that 0041 is allowed to leave behind; the two compatibility writer roles
-- must remain completely inert.
CREATE FUNCTION ops.assert_r6e_runtime_role_postconditions_v1()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path=pg_catalog,pg_temp
AS $r6e_role_postconditions$
WITH expected_roles(role_name,can_login,connection_limit) AS (
  VALUES
    ('gurine_economics_writer',false,-1),
    ('gurine_payment_writer',false,-1),
    ('gurine_billing_gateway',true,8),
    ('gurine_economics_importer',true,4)
), target_roles AS (
  SELECT role_state.oid,role_state.rolname
  FROM pg_roles AS role_state
  JOIN expected_roles AS expected ON expected.role_name=role_state.rolname
), expected_schema_acl(role_name,schema_oid,privilege_type) AS (
  VALUES
    ('gurine_billing_gateway','ops'::regnamespace::oid,'USAGE'),
    ('gurine_economics_importer','ops'::regnamespace::oid,'USAGE')
), actual_schema_acl AS (
  SELECT target.rolname AS role_name,namespace.oid AS schema_oid,
    acl.privilege_type
  FROM pg_namespace AS namespace
  CROSS JOIN LATERAL aclexplode(COALESCE(
    namespace.nspacl,acldefault('n',namespace.nspowner)
  )) AS acl
  JOIN target_roles AS target ON target.oid=acl.grantee
), expected_function_acl(role_name,routine_oid,privilege_type) AS (
  VALUES
    ('gurine_billing_gateway',
      'ops.consume_billing_gateway_assertion_jti_v1(text,uuid,text,text,timestamptz,bpchar)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.claim_r6e_donation_intent_v1(ops.r6e_donation_intent_claim_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.complete_r6e_payment_method_binding_v1(ops.r6e_payment_method_binding_complete_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.fail_r6e_donation_intent_v1(ops.r6e_donation_intent_fail_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.claim_r6e_donation_charge_job_v1(ops.r6e_donation_charge_job_claim_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.claim_r6e_donation_charge_v1(ops.r6e_donation_charge_claim_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.accept_r6e_donation_charge_v1(ops.r6e_donation_charge_accept_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.complete_r6e_donation_charge_v1(ops.r6e_donation_charge_complete_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.fail_r6e_donation_charge_v1(ops.r6e_donation_charge_fail_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.require_r6e_charge_reconciliation_v1(ops.r6e_charge_reconciliation_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.claim_r6e_provider_webhook_v1(ops.r6e_provider_webhook_claim_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.complete_r6e_provider_webhook_v1(ops.r6e_provider_webhook_complete_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_billing_gateway',
      'ops.release_r6e_provider_webhook_claim_v1(ops.r6e_provider_webhook_release_v1)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_economics_importer',
      'ops.claim_economics_import_execution_v1(uuid,uuid,bigint,uuid,uuid,bigint,bpchar,bpchar,text)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_economics_importer',
      'ops.fail_economics_import_execution_v1(uuid,uuid,bigint,uuid,bigint,text,bpchar,uuid)'::regprocedure::oid,
      'EXECUTE'),
    ('gurine_economics_importer',
      'ops.complete_economics_import_execution_v1(uuid,uuid,bigint,uuid,bigint,uuid)'::regprocedure::oid,
      'EXECUTE')
), actual_function_acl AS (
  SELECT target.rolname AS role_name,routine.oid AS routine_oid,
    acl.privilege_type,acl.is_grantable
  FROM pg_proc AS routine
  CROSS JOIN LATERAL aclexplode(COALESCE(
    routine.proacl,acldefault('f',routine.proowner)
  )) AS acl
  JOIN target_roles AS target ON target.oid=acl.grantee
), expected_type_acl(role_name,type_oid,privilege_type) AS (
  VALUES
    ('gurine_billing_gateway','ops.r6e_donation_intent_claim_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_intent_claim_receipt_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_payment_method_binding_complete_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_payment_method_binding_receipt_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_intent_fail_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_payment_transition_receipt_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_charge_claim_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_charge_job_claim_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_charge_job_claim_receipt_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_charge_claim_receipt_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_payment_observation_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_charge_complete_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_charge_accept_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_charge_fail_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_donation_charge_terminal_receipt_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_charge_reconciliation_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_provider_webhook_claim_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_provider_webhook_claim_receipt_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_provider_webhook_complete_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_provider_webhook_receipt_v1'::regtype::oid,'USAGE'),
    ('gurine_billing_gateway','ops.r6e_provider_webhook_release_v1'::regtype::oid,'USAGE')
), actual_type_acl AS (
  SELECT target.rolname AS role_name,type_state.oid AS type_oid,
    acl.privilege_type,acl.is_grantable
  FROM pg_type AS type_state
  CROSS JOIN LATERAL aclexplode(COALESCE(
    type_state.typacl,acldefault('T',type_state.typowner)
  )) AS acl
  JOIN target_roles AS target ON target.oid=acl.grantee
), relation_or_column_acl AS (
  SELECT target.rolname
  FROM pg_class AS relation
  CROSS JOIN LATERAL aclexplode(COALESCE(
    relation.relacl,
    acldefault(CASE WHEN relation.relkind='S' THEN 'S'::"char" ELSE 'r'::"char" END,
      relation.relowner)
  )) AS acl
  JOIN target_roles AS target ON target.oid=acl.grantee
  UNION ALL
  SELECT target.rolname
  FROM pg_attribute AS attribute
  CROSS JOIN LATERAL aclexplode(attribute.attacl) AS acl
  JOIN target_roles AS target ON target.oid=acl.grantee
), database_or_default_acl AS (
  SELECT target.rolname
  FROM pg_database AS database_state
  CROSS JOIN LATERAL aclexplode(COALESCE(
    database_state.datacl,acldefault('d',database_state.datdba)
  )) AS acl
  JOIN target_roles AS target ON target.oid=acl.grantee
  UNION ALL
  SELECT target.rolname
  FROM pg_default_acl AS default_acl
  CROSS JOIN LATERAL aclexplode(default_acl.defaclacl) AS acl
  JOIN target_roles AS target ON target.oid=acl.grantee
)
SELECT
  (SELECT count(*)=4 AND bool_and(
    NOT role_state.rolsuper
    AND NOT role_state.rolinherit
    AND NOT role_state.rolcreaterole
    AND NOT role_state.rolcreatedb
    AND NOT role_state.rolreplication
    AND NOT role_state.rolbypassrls
    AND role_state.rolcanlogin=expected.can_login
    AND role_state.rolconnlimit=expected.connection_limit
    AND role_state.rolvaliduntil IS NULL
    AND role_state.rolconfig IS NULL
  )
  FROM expected_roles AS expected
  JOIN pg_roles AS role_state ON role_state.rolname=expected.role_name)
  AND NOT EXISTS (
    SELECT 1 FROM pg_auth_members AS membership
    JOIN target_roles AS target
      ON target.oid=membership.roleid OR target.oid=membership.member
  )
  AND NOT EXISTS (
    SELECT 1 FROM pg_db_role_setting AS setting
    JOIN target_roles AS target ON target.oid=setting.setrole
  )
  AND NOT EXISTS (
    SELECT 1 FROM pg_shdepend AS dependency
    JOIN target_roles AS target ON target.oid=dependency.refobjid
    WHERE dependency.refclassid='pg_authid'::regclass
      AND dependency.deptype='o'
  )
  AND NOT EXISTS (
    SELECT 1 FROM pg_shdepend AS dependency
    JOIN target_roles AS target ON target.oid=dependency.refobjid
    WHERE dependency.refclassid='pg_authid'::regclass
      AND dependency.deptype='a'
      AND target.rolname IN (
        'gurine_economics_writer','gurine_payment_writer'
      )
  )
  AND NOT EXISTS (
    (SELECT * FROM actual_schema_acl
      EXCEPT SELECT * FROM expected_schema_acl)
    UNION ALL
    (SELECT * FROM expected_schema_acl
      EXCEPT SELECT * FROM actual_schema_acl)
  )
  AND NOT EXISTS (
    (SELECT role_name,routine_oid,privilege_type FROM actual_function_acl
      EXCEPT SELECT * FROM expected_function_acl)
    UNION ALL
    (SELECT * FROM expected_function_acl
      EXCEPT SELECT role_name,routine_oid,privilege_type FROM actual_function_acl)
  )
  AND NOT EXISTS (SELECT 1 FROM actual_function_acl WHERE is_grantable)
  AND NOT EXISTS (
    (SELECT role_name,type_oid,privilege_type FROM actual_type_acl
      EXCEPT SELECT * FROM expected_type_acl)
    UNION ALL
    (SELECT * FROM expected_type_acl
      EXCEPT SELECT role_name,type_oid,privilege_type FROM actual_type_acl)
  )
  AND NOT EXISTS (SELECT 1 FROM actual_type_acl WHERE is_grantable)
  AND NOT EXISTS (SELECT 1 FROM relation_or_column_acl)
  AND NOT EXISTS (SELECT 1 FROM database_or_default_acl)
$r6e_role_postconditions$;
ALTER FUNCTION ops.assert_r6e_runtime_role_postconditions_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.assert_r6e_runtime_role_postconditions_v1()
FROM PUBLIC,gurine_public_api,gurine_control_api,gurine_workflow_worker,
  gurine_analysis_worker,gurine_notification_worker,gurine_submission_api,
  gurine_ingest_worker,gurine_public_projector,gurine_scheduler,
  gurine_document_extractor,gurine_identity_api,gurine_auditor,
  gurine_billing_gateway,gurine_economics_importer,
  gurine_economics_writer,gurine_payment_writer,gurine_egress_gateway;

DO $r6e_role_postcondition_assertion$
BEGIN
  IF ops.assert_r6e_runtime_role_postconditions_v1() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'R6E_RUNTIME_ROLE_POSTCONDITION_FAILED'
      USING ERRCODE='42501';
  END IF;
END
$r6e_role_postcondition_assertion$;

COMMIT;
