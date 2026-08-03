-- R6b restores the v2 physical contracts already declared by the 0025
-- addendum.  Legacy rows remain nullable bridges and are never synthesized.

-- Structured connector parser identity.  The implementation bundle is every
-- ingest-worker source plus its manifest, path-sorted bytewise and measured
-- from this unchanged worktree with:
-- LC_ALL=C find services/ingest-worker -type f \
--   \( -path 'services/ingest-worker/Cargo.toml' \
--      -o -path 'services/ingest-worker/src/*.rs' \
--      -o -path 'services/ingest-worker/src/**/*.rs' \) -print0 \
--   | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
INSERT INTO core.parser_versions(
  parser_name, version, supported_media_types, implementation_digest,
  sandbox_profile, status
) VALUES (
  'connector-structured-json',
  'connector-structured-json-v1',
  '["application/json"]'::jsonb,
  'addf2fb260bf760b6cdd86fa1daaf129e4d7ac4f232e77400f8413cd90b45ad2'::char(64),
  'pure-rust-no-network-v1',
  'ACTIVE'
);

ALTER TABLE raw.source_documents
  ADD CONSTRAINT source_documents_parser_content_uk UNIQUE (id, content_sha256);

ALTER TABLE core.parser_runs
  ADD COLUMN input_content_sha256 char(64),
  ADD COLUMN extraction_schema_version text,
  ADD COLUMN implementation_sha256 char(64),
  ADD COLUMN extraction_receipt_sha256 char(64),
  ADD CONSTRAINT parser_runs_segment_binding_uk
    UNIQUE (id, source_document_id, parser_name, parser_version),
  ADD CONSTRAINT parser_runs_source_binding_uk
    UNIQUE (id, source_document_id),
  ADD CONSTRAINT parser_runs_extraction_binding_uk UNIQUE (
    id, source_document_id, input_content_sha256, parser_name, parser_version,
    output_digest, extraction_receipt_sha256
  ),
  ADD CONSTRAINT parser_runs_source_content_fk FOREIGN KEY (
    source_document_id, input_content_sha256
  ) REFERENCES raw.source_documents(id, content_sha256) ON DELETE RESTRICT,
  ADD CONSTRAINT parser_runs_v2_shape_ck CHECK (
    num_nonnulls(
      input_content_sha256, extraction_schema_version,
      implementation_sha256, extraction_receipt_sha256
    ) = 0
    OR (
      status = 'SUCCEEDED'
      AND num_nonnulls(
        input_content_sha256, extraction_schema_version,
        implementation_sha256, extraction_receipt_sha256
      ) = 4
      AND output_digest IS NOT NULL
      AND input_content_sha256 ~ '^[0-9a-f]{64}$'
      AND implementation_sha256 ~ '^[0-9a-f]{64}$'
      AND extraction_receipt_sha256 ~ '^[0-9a-f]{64}$'
      AND nullif(btrim(extraction_schema_version), '') IS NOT NULL
    )
  );

GRANT SELECT, INSERT ON core.parser_runs TO gurine_ingest_worker;

ALTER TABLE raw.parsed_records
  ADD COLUMN parser_run_id uuid,
  ADD CONSTRAINT parsed_records_normalization_binding_uk
    UNIQUE (id, source_document_id, parser_version, payload_sha256),
  ADD CONSTRAINT parsed_records_parser_binding_uk
    UNIQUE (id, source_document_id, parser_run_id, parser_version, payload_sha256),
  ADD CONSTRAINT parsed_records_provenance_binding_uk
    UNIQUE (id, source_document_id, parser_run_id, parser_version),
  ADD CONSTRAINT parsed_records_source_run_binding_uk
    UNIQUE (id, source_document_id, parser_run_id),
  ADD CONSTRAINT parsed_records_parser_run_fk FOREIGN KEY (
    parser_run_id, source_document_id
  ) REFERENCES core.parser_runs(id, source_document_id) ON DELETE RESTRICT;

ALTER TABLE core.field_provenance
  ADD COLUMN normalization_run_id uuid,
  ADD COLUMN parser_run_id uuid,
  ADD COLUMN parsed_record_id uuid,
  ADD COLUMN entity_version bigint,
  ADD CONSTRAINT field_provenance_normalization_run_fk
    FOREIGN KEY (normalization_run_id)
    REFERENCES core.normalization_runs(id) ON DELETE RESTRICT,
  ADD CONSTRAINT field_provenance_parser_run_fk
    FOREIGN KEY (parser_run_id, source_document_id)
    REFERENCES core.parser_runs(id, source_document_id) ON DELETE RESTRICT,
  ADD CONSTRAINT field_provenance_parsed_record_fk
    FOREIGN KEY (
      parsed_record_id, source_document_id, parser_run_id, parser_version
    ) REFERENCES raw.parsed_records(
      id, source_document_id, parser_run_id, parser_version
    ) ON DELETE RESTRICT,
  ADD CONSTRAINT field_provenance_member_binding_uk UNIQUE (
    id, source_document_id, normalization_run_id, parser_run_id, parsed_record_id
  ),
  ADD CONSTRAINT field_provenance_v2_shape_ck CHECK (
    num_nonnulls(
      normalization_run_id, parser_run_id, parsed_record_id, entity_version
    ) = 0
    OR (
      num_nonnulls(
        normalization_run_id, parser_run_id, parsed_record_id, entity_version
      ) = 4
      AND entity_version > 0
    )
  );

ALTER TABLE core.normalization_runs
  ADD CONSTRAINT normalization_runs_source_document_fk
    FOREIGN KEY (source_document_id)
    REFERENCES raw.source_documents(id) ON DELETE RESTRICT,
  ADD CONSTRAINT normalization_runs_parser_run_fk
    FOREIGN KEY (parser_run_id, source_document_id)
    REFERENCES core.parser_runs(id, source_document_id) ON DELETE RESTRICT,
  ADD CONSTRAINT normalization_runs_parsed_record_fk
    FOREIGN KEY (
      parsed_record_id, source_document_id, parser_version, input_payload_sha256
    ) REFERENCES raw.parsed_records(
      id, source_document_id, parser_version, payload_sha256
    ) ON DELETE RESTRICT,
  ADD CONSTRAINT normalization_runs_job_fk
    FOREIGN KEY (job_id) REFERENCES ops.jobs(id) ON DELETE RESTRICT,
  ADD CONSTRAINT normalization_runs_terminal_audit_fk
    FOREIGN KEY (terminal_audit_event_id)
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT;

CREATE UNIQUE INDEX normalization_runs_one_active_uk
  ON core.normalization_runs(
    parsed_record_id, normalization_id, normalization_version
  ) WHERE state = 'RUNNING';

ALTER TABLE core.dataset_snapshots
  ADD CONSTRAINT dataset_snapshots_job_fk
    FOREIGN KEY (producer_job_id) REFERENCES ops.jobs(id) ON DELETE RESTRICT,
  ADD CONSTRAINT dataset_snapshots_build_audit_fk
    FOREIGN KEY (build_started_audit_event_id)
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  ADD CONSTRAINT dataset_snapshots_terminal_audit_fk
    FOREIGN KEY (terminal_audit_event_id)
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT;

ALTER TABLE core.dataset_snapshot_member_sources
  ADD CONSTRAINT dataset_snapshot_member_sources_document_fk FOREIGN KEY (
    source_document_id, source_asset_id, source_asset_revision,
    source_content_sha256
  ) REFERENCES raw.source_documents(
    id, asset_id, asset_revision, content_sha256
  ) ON DELETE RESTRICT,
  ADD CONSTRAINT dataset_snapshot_member_sources_parser_fk FOREIGN KEY (
    parser_run_id, source_document_id
  ) REFERENCES core.parser_runs(id, source_document_id) ON DELETE RESTRICT,
  ADD CONSTRAINT dataset_snapshot_member_sources_parsed_fk FOREIGN KEY (
    parsed_record_id, source_document_id, parser_run_id
  ) REFERENCES raw.parsed_records(
    id, source_document_id, parser_run_id
  ) ON DELETE RESTRICT,
  ADD CONSTRAINT dataset_snapshot_member_sources_provenance_fk FOREIGN KEY (
    field_provenance_id, source_document_id, normalization_run_id,
    parser_run_id, parsed_record_id
  ) REFERENCES core.field_provenance(
    id, source_document_id, normalization_run_id, parser_run_id,
    parsed_record_id
  ) ON DELETE RESTRICT;

ALTER TABLE core.rule_runs
  ADD COLUMN dataset_snapshot_id uuid,
  ADD COLUMN dataset_snapshot_sha256 char(64),
  ADD COLUMN rule_configuration_sha256 char(64),
  ADD COLUMN rule_code_sha256 char(64),
  ADD CONSTRAINT rule_runs_snapshot_fk FOREIGN KEY (
    dataset_snapshot_id, dataset_snapshot_sha256
  ) REFERENCES core.dataset_snapshots(id, snapshot_sha256) ON DELETE RESTRICT,
  ADD CONSTRAINT rule_runs_v2_shape_ck CHECK (
    num_nonnulls(
      dataset_snapshot_id, dataset_snapshot_sha256,
      rule_configuration_sha256, rule_code_sha256
    ) IN (0, 4)
  );

ALTER TABLE core.rule_evaluations
  ADD COLUMN requester_type text NOT NULL DEFAULT 'USER',
  ADD COLUMN requester_service text,
  ALTER COLUMN requested_by DROP NOT NULL,
  ADD CONSTRAINT rule_evaluations_requester_ck CHECK (
    (
      requester_type = 'USER'
      AND requested_by IS NOT NULL
      AND requester_service IS NULL
    )
    OR (
      requester_type = 'SERVICE'
      AND requested_by IS NULL
      AND requester_service = 'snapshot-producer'
    )
  );

-- AgentRunV2 is a nullable bridge for v1 rows.  New v2 rows bind all model,
-- prompt, budget and snapshot authority in one closed shape.
ALTER TABLE ops.agent_runs
  ADD COLUMN run_contract_version smallint NOT NULL DEFAULT 1,
  ADD COLUMN dataset_snapshot_id uuid,
  ADD COLUMN initial_transcript_sha256 char(64),
  ADD COLUMN control_state text,
  ADD COLUMN prompt_id text,
  ADD COLUMN prompt_version text,
  ADD COLUMN prompt_sha256 char(64),
  ADD COLUMN output_schema_id text,
  ADD COLUMN output_schema_contract_version text,
  ADD COLUMN output_schema_sha256 char(64),
  ADD COLUMN provider_policy_version text,
  ADD COLUMN provider_policy_sha256 char(64),
  ADD COLUMN provider_classification text,
  ADD COLUMN provider_candidate_ids text[],
  ADD COLUMN max_micros_krw bigint,
  ADD COLUMN reserved_micros_krw bigint,
  ADD COLUMN settled_micros_krw bigint,
  ADD COLUMN remaining_micros_krw bigint,
  ADD COLUMN budget_reservation_state text,
  ADD COLUMN budget_policy_version text,
  ADD COLUMN budget_policy_sha256 char(64),
  ADD COLUMN max_provider_turns integer,
  ADD COLUMN max_tool_calls integer,
  ADD COLUMN completed_provider_turns integer,
  ADD COLUMN completed_tool_calls integer,
  ADD COLUMN next_turn_sequence integer,
  ADD COLUMN deadline_at timestamptz,
  ADD COLUMN output_validation_id uuid,
  ADD COLUMN failure_code text,
  ADD COLUMN terminal_receipt_sha256 char(64),
  ADD COLUMN created_actor_type text NOT NULL DEFAULT 'HUMAN',
  ADD COLUMN created_service text,
  ALTER COLUMN created_by DROP NOT NULL,
  ADD CONSTRAINT agent_runs_contract_version_ck
    CHECK (run_contract_version IN (1, 2)),
  ADD CONSTRAINT agent_runs_snapshot_hash_uk UNIQUE (id, input_snapshot_hash),
  ADD CONSTRAINT agent_runs_snapshot_binding_uk
    UNIQUE (id, dataset_snapshot_id, input_snapshot_hash),
  ADD CONSTRAINT agent_runs_snapshot_fk FOREIGN KEY (
    dataset_snapshot_id, input_snapshot_hash
  ) REFERENCES core.dataset_snapshots(id, snapshot_sha256) ON DELETE RESTRICT,
  ADD CONSTRAINT agent_runs_v2_output_validation_fk FOREIGN KEY (
    output_validation_id, id, input_snapshot_hash
  ) REFERENCES ops.agent_output_validations(
    validation_id, agent_run_id, input_snapshot_sha256
  ) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  ADD CONSTRAINT agent_runs_actor_ck CHECK (
    (
      created_actor_type = 'HUMAN'
      AND created_by IS NOT NULL
      AND created_service IS NULL
    )
    OR (
      created_actor_type = 'SERVICE'
      AND created_by IS NULL
      AND created_service = 'workflow-worker'
    )
  ),
  ADD CONSTRAINT agent_runs_v2_shape_ck CHECK (
    run_contract_version = 1
    OR (
      dataset_snapshot_id IS NOT NULL
      AND initial_transcript_sha256 IS NOT NULL
      AND control_state IS NOT NULL
      AND prompt_id IS NOT NULL
      AND prompt_version IS NOT NULL
      AND prompt_sha256 IS NOT NULL
      AND output_schema_id IS NOT NULL
      AND output_schema_contract_version IS NOT NULL
      AND output_schema_sha256 IS NOT NULL
      AND provider_policy_version IS NOT NULL
      AND provider_policy_sha256 IS NOT NULL
      AND provider_classification IS NOT NULL
      AND provider_candidate_ids IS NOT NULL
      AND cardinality(provider_candidate_ids) BETWEEN 1 AND 8
      AND max_micros_krw IS NOT NULL
      AND max_micros_krw >= 0
      AND reserved_micros_krw IS NOT NULL
      AND reserved_micros_krw >= 0
      AND settled_micros_krw IS NOT NULL
      AND settled_micros_krw >= 0
      AND remaining_micros_krw IS NOT NULL
      AND remaining_micros_krw >= 0
      AND budget_reservation_state IS NOT NULL
      AND budget_policy_version IS NOT NULL
      AND budget_policy_sha256 IS NOT NULL
      AND max_provider_turns IS NOT NULL
      AND max_provider_turns BETWEEN 1 AND 32
      AND max_tool_calls IS NOT NULL
      AND max_tool_calls BETWEEN 0 AND 32
      AND completed_provider_turns IS NOT NULL
      AND completed_provider_turns BETWEEN 0 AND max_provider_turns
      AND completed_tool_calls IS NOT NULL
      AND completed_tool_calls BETWEEN 0 AND max_tool_calls
      AND next_turn_sequence IS NOT NULL
      AND next_turn_sequence BETWEEN 1 AND 33
      AND deadline_at IS NOT NULL
      AND deadline_at > created_at
      AND evidence_scope_ids = '[]'::jsonb
    )
  ),
  ADD CONSTRAINT agent_runs_v2_status_control_ck CHECK (
    run_contract_version = 1
    OR (
      status = 'QUEUED' AND control_state = 'NONE'
      AND started_at IS NULL AND completed_at IS NULL
      AND terminal_receipt_sha256 IS NULL
    )
    OR (
      status = 'RUNNING'
      AND control_state IN (
        'ACTIVE', 'CANCEL_REQUESTED', 'RECONCILIATION_REQUIRED'
      )
      AND started_at IS NOT NULL AND completed_at IS NULL
      AND terminal_receipt_sha256 IS NULL
    )
    OR (
      status IN (
        'SUCCEEDED', 'FAILED', 'CANCELLED',
        'BUDGET_BLOCKED', 'POLICY_BLOCKED'
      )
      AND control_state = 'SETTLED'
      AND completed_at IS NOT NULL
      AND terminal_receipt_sha256 IS NOT NULL
    )
  ),
  ADD CONSTRAINT agent_runs_v2_failure_ck CHECK (
    failure_code IS NULL OR failure_code IN (
      'OUTPUT_SCHEMA_INVALID', 'PROVIDER_UNAVAILABLE',
      'INTERNAL_EXECUTION_FAILED', 'CITATION_INVALID', 'RIGHTS_DENIED',
      'CLASSIFICATION_DENIED', 'ITERATION_LIMIT_REACHED',
      'CANCELLED_BY_USER', 'RECONCILIATION_FAILED'
    )
  ),
  ADD CONSTRAINT agent_runs_v2_enum_ck CHECK (
    run_contract_version = 1
    OR (
      agent_type IN (
        'market-researcher', 'investigator', 'skeptic',
        'claim-drafter', 'citation-verifier'
      )
      AND provider_classification IN (
        'PUBLIC', 'INTERNAL', 'RESTRICTED', 'PERSONAL_DATA', 'LEGAL_HOLD'
      )
    )
  ),
  ADD CONSTRAINT agent_runs_v2_budget_ck CHECK (
    run_contract_version = 1
    OR (
      budget_reservation_state IN (
        'NONE', 'RESERVED', 'PARTIALLY_SETTLED', 'SETTLED', 'RELEASED',
        'RECONCILIATION_REQUIRED'
      )
      AND reserved_micros_krw <= max_micros_krw
      AND settled_micros_krw <= reserved_micros_krw
      AND remaining_micros_krw = max_micros_krw - settled_micros_krw
    )
  ),
  ADD CONSTRAINT agent_runs_v2_candidates_ck CHECK (
    run_contract_version = 1
    OR ops.agent_provider_candidates_are_valid(provider_candidate_ids)
  );

ALTER TABLE editorial.case_signals
  ADD COLUMN linked_actor_type text NOT NULL DEFAULT 'HUMAN',
  ADD COLUMN linked_service text,
  ALTER COLUMN linked_by DROP NOT NULL,
  ADD CONSTRAINT case_signals_linked_actor_ck CHECK (
    (
      linked_actor_type = 'HUMAN'
      AND linked_by IS NOT NULL
      AND linked_service IS NULL
    )
    OR (
      linked_actor_type = 'SERVICE'
      AND linked_by IS NULL
      AND linked_service = 'workflow-worker'
    )
  );

ALTER TABLE core.supplier_identifiers
  ADD COLUMN candidate_id uuid,
  ADD COLUMN candidate_revision bigint,
  ADD COLUMN candidate_digest char(64),
  ADD COLUMN source_locator_digest char(64),
  ADD COLUMN verification_evidence_digest char(64),
  ADD COLUMN identifier_fact_digest char(64),
  ADD COLUMN proof_state text NOT NULL DEFAULT 'LEGACY_UNPROVEN',
  ADD CONSTRAINT supplier_identifiers_candidate_fk FOREIGN KEY (
    candidate_id, candidate_revision, candidate_digest
  ) REFERENCES core.supplier_identity_candidates(
    candidate_id, candidate_revision, candidate_digest
  ) MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT supplier_identifiers_proof_shape_ck CHECK (
    (
      proof_state = 'LEGACY_UNPROVEN'
      AND num_nonnulls(
        candidate_id, candidate_revision, candidate_digest,
        source_locator_digest, verification_evidence_digest,
        identifier_fact_digest
      ) = 0
    )
    OR (
      proof_state = 'PROVEN_V1'
      AND scheme IN (
        'KOREAN_BUSINESS_NUMBER', 'OPEN_DART_CORP_CODE', 'KONEPS_PARTY_KEY'
      )
      AND verification_status = 'VERIFIED'
      AND candidate_revision > 0
      AND num_nonnulls(
        candidate_id, candidate_revision, candidate_digest,
        source_locator_digest, verification_evidence_digest,
        identifier_fact_digest
      ) = 6
    )
  );

CREATE UNIQUE INDEX supplier_identifiers_fact_uq
  ON core.supplier_identifiers(
    candidate_id, candidate_revision, scheme, identifier_fact_digest
  ) WHERE proof_state = 'PROVEN_V1';

-- The policy is append-only and intentionally unseeded.  An enabled row is
-- structurally complete; therefore enabled-but-incomplete cannot degrade into
-- a permissive runtime disposition.
CREATE OR REPLACE FUNCTION ops.reject_signal_investigation_mutation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'signal_investigation_record_is_immutable'
    USING ERRCODE = '55000';
END
$$;
ALTER FUNCTION ops.reject_signal_investigation_mutation()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.reject_signal_investigation_mutation() FROM PUBLIC;

CREATE TABLE ops.signal_investigation_policies (
  policy_id uuid NOT NULL DEFAULT gen_random_uuid(),
  policy_key text NOT NULL DEFAULT 'AUTO_SIGNAL_INVESTIGATION',
  version bigint NOT NULL,
  enabled boolean NOT NULL DEFAULT false,
  minimum_severity text,
  dedupe_window interval,
  daily_run_limit integer,
  case_daily_run_limit integer,
  daily_budget_micros_krw bigint,
  max_run_micros_krw bigint,
  kill_switch_code text,
  agent_type text,
  prompt_id text,
  prompt_version text,
  prompt_sha256 char(64),
  output_schema_id text,
  output_schema_version text,
  output_schema_sha256 char(64),
  provider_policy_version text,
  provider_policy_sha256 char(64),
  provider_classification text,
  provider_candidate_ids text[],
  budget_policy_version text,
  budget_policy_sha256 char(64),
  max_provider_turns integer,
  max_tool_calls integer,
  deadline_interval interval,
  created_by uuid,
  policy_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT signal_investigation_policies_pk PRIMARY KEY (policy_id),
  CONSTRAINT signal_investigation_policies_version_uq
    UNIQUE (policy_key, version),
  CONSTRAINT signal_investigation_policies_id_version_uq
    UNIQUE (policy_id, version),
  CONSTRAINT signal_investigation_policies_creator_fk
    FOREIGN KEY (created_by) REFERENCES ops.users(id) ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_policies_key_ck CHECK (
    policy_key = 'AUTO_SIGNAL_INVESTIGATION'
  ),
  CONSTRAINT signal_investigation_policies_scalar_ck CHECK (
    version > 0
    AND policy_digest ~ '^[0-9a-f]{64}$'
    AND (
      minimum_severity IS NULL OR minimum_severity IN (
        'INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'
      )
    )
  ),
  CONSTRAINT signal_investigation_policies_enabled_ck CHECK (
    NOT enabled
    OR (
      minimum_severity IS NOT NULL
      AND dedupe_window IS NOT NULL
      AND dedupe_window > interval '0 seconds'
      AND daily_run_limit IS NOT NULL
      AND daily_run_limit > 0
      AND case_daily_run_limit IS NOT NULL
      AND case_daily_run_limit > 0
      AND daily_budget_micros_krw IS NOT NULL
      AND daily_budget_micros_krw >= 0
      AND max_run_micros_krw IS NOT NULL
      AND max_run_micros_krw >= 0
      AND max_run_micros_krw <= daily_budget_micros_krw
      AND nullif(btrim(kill_switch_code), '') IS NOT NULL
      AND agent_type IS NOT NULL
      AND agent_type = 'investigator'
      AND nullif(btrim(prompt_id), '') IS NOT NULL
      AND nullif(btrim(prompt_version), '') IS NOT NULL
      AND prompt_sha256 IS NOT NULL
      AND prompt_sha256 ~ '^[0-9a-f]{64}$'
      AND nullif(btrim(output_schema_id), '') IS NOT NULL
      AND nullif(btrim(output_schema_version), '') IS NOT NULL
      AND output_schema_sha256 IS NOT NULL
      AND output_schema_sha256 ~ '^[0-9a-f]{64}$'
      AND nullif(btrim(provider_policy_version), '') IS NOT NULL
      AND provider_policy_sha256 IS NOT NULL
      AND provider_policy_sha256 ~ '^[0-9a-f]{64}$'
      AND provider_classification IS NOT NULL
      AND provider_classification IN (
        'PUBLIC', 'INTERNAL', 'RESTRICTED', 'PERSONAL_DATA', 'LEGAL_HOLD'
      )
      AND provider_candidate_ids IS NOT NULL
      AND ops.agent_provider_candidates_are_valid(provider_candidate_ids)
      AND nullif(btrim(budget_policy_version), '') IS NOT NULL
      AND budget_policy_sha256 IS NOT NULL
      AND budget_policy_sha256 ~ '^[0-9a-f]{64}$'
      AND max_provider_turns IS NOT NULL
      AND max_provider_turns BETWEEN 1 AND 32
      AND max_tool_calls IS NOT NULL
      AND max_tool_calls BETWEEN 0 AND 32
      AND deadline_interval IS NOT NULL
      AND deadline_interval > interval '0 seconds'
      AND created_by IS NOT NULL
    )
  )
);
ALTER TABLE ops.signal_investigation_policies OWNER TO gurine_migrator;
REVOKE ALL ON ops.signal_investigation_policies FROM PUBLIC;
GRANT SELECT ON ops.signal_investigation_policies TO gurine_workflow_worker;
CREATE TRIGGER signal_investigation_policies_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.signal_investigation_policies
  FOR EACH ROW EXECUTE FUNCTION ops.reject_signal_investigation_mutation();

CREATE TABLE ops.signal_investigation_initiation_receipts (
  receipt_id uuid NOT NULL DEFAULT gen_random_uuid(),
  signal_id uuid NOT NULL,
  rule_version_id uuid NOT NULL,
  target_type text NOT NULL,
  target_id uuid NOT NULL,
  producer_job_id uuid NOT NULL,
  policy_id uuid,
  policy_version bigint,
  disposition text NOT NULL,
  case_id uuid,
  dataset_snapshot_id uuid,
  agent_run_id uuid,
  job_id uuid,
  reserved_micros_krw bigint NOT NULL DEFAULT 0,
  actor_type text NOT NULL DEFAULT 'SERVICE',
  actor_id text NOT NULL DEFAULT 'workflow-worker',
  audit_event_id uuid NOT NULL,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT signal_investigation_receipts_pk PRIMARY KEY (receipt_id),
  CONSTRAINT signal_investigation_receipts_signal_uq UNIQUE (signal_id),
  CONSTRAINT signal_investigation_receipts_digest_uq UNIQUE (receipt_digest),
  CONSTRAINT signal_investigation_receipts_signal_fk
    FOREIGN KEY (signal_id)
    REFERENCES core.anomaly_signals(id) ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_receipts_rule_fk
    FOREIGN KEY (rule_version_id)
    REFERENCES core.rule_versions(id) ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_receipts_producer_job_fk
    FOREIGN KEY (producer_job_id) REFERENCES ops.jobs(id) ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_receipts_case_fk
    FOREIGN KEY (case_id) REFERENCES editorial.cases(id) ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_receipts_snapshot_fk
    FOREIGN KEY (dataset_snapshot_id)
    REFERENCES core.dataset_snapshots(id) ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_receipts_agent_run_fk
    FOREIGN KEY (agent_run_id) REFERENCES ops.agent_runs(id) ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_receipts_job_fk
    FOREIGN KEY (job_id) REFERENCES ops.jobs(id) ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_receipts_audit_fk
    FOREIGN KEY (audit_event_id)
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_receipts_policy_fk FOREIGN KEY (
    policy_id, policy_version
  ) REFERENCES ops.signal_investigation_policies(
    policy_id, version
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT signal_investigation_receipts_policy_shape_ck CHECK (
    (policy_id IS NULL) = (policy_version IS NULL)
  ),
  CONSTRAINT signal_investigation_receipts_actor_ck CHECK (
    actor_type = 'SERVICE' AND actor_id = 'workflow-worker'
  ),
  CONSTRAINT signal_investigation_receipts_disposition_ck CHECK (
    disposition IN (
      'STARTED', 'POLICY_ABSENT', 'POLICY_DISABLED', 'KILL_SWITCH_ACTIVE',
      'BELOW_MIN_SEVERITY', 'DUPLICATE_SUPPRESSED',
      'DAILY_LIMIT_REACHED', 'CASE_DAILY_LIMIT_REACHED', 'BUDGET_BLOCKED',
      'EVIDENCE_SCOPE_DENIED', 'PROVIDER_UNAVAILABLE'
    )
  ),
  CONSTRAINT signal_investigation_receipts_started_shape_ck CHECK (
    (
      disposition = 'STARTED'
      AND num_nonnulls(case_id, dataset_snapshot_id, agent_run_id, job_id) = 4
      AND policy_id IS NOT NULL
      AND reserved_micros_krw >= 0
    )
    OR (
      disposition <> 'STARTED'
      AND num_nonnulls(case_id, dataset_snapshot_id, agent_run_id, job_id) = 0
      AND reserved_micros_krw = 0
    )
  ),
  CONSTRAINT signal_investigation_receipts_canonical_ck CHECK (
    convert_from(receipt_canonical, 'UTF8')::jsonb = receipt_payload
    AND receipt_digest = encode(
      extensions.digest(receipt_canonical, 'sha256'), 'hex'
    )
  )
);
ALTER TABLE ops.signal_investigation_initiation_receipts OWNER TO gurine_migrator;
REVOKE ALL ON ops.signal_investigation_initiation_receipts FROM PUBLIC;
GRANT SELECT ON ops.signal_investigation_initiation_receipts
  TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
CREATE TRIGGER signal_investigation_receipts_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.signal_investigation_initiation_receipts
  FOR EACH ROW EXECUTE FUNCTION ops.reject_signal_investigation_mutation();

CREATE INDEX signal_investigation_receipts_target_time_idx
  ON ops.signal_investigation_initiation_receipts(
    rule_version_id, target_type, target_id, created_at DESC
  );
CREATE INDEX signal_investigation_receipts_case_time_idx
  ON ops.signal_investigation_initiation_receipts(case_id, created_at DESC)
  WHERE disposition = 'STARTED';

GRANT SELECT ON ops.source_checkpoints TO gurine_analysis_worker;

CREATE UNIQUE INDEX dataset_snapshots_one_building_uk
  ON core.dataset_snapshots(snapshot_kind, producer_digest)
  WHERE state = 'BUILDING';

CREATE OR REPLACE FUNCTION core.assert_v2_rule_run_snapshot()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, pg_temp
AS $$
BEGIN
  IF NEW.dataset_snapshot_id IS NULL THEN
    RETURN NEW;
  END IF;
  PERFORM 1
  FROM core.dataset_snapshots AS snapshot
  WHERE snapshot.id = NEW.dataset_snapshot_id
    AND snapshot.snapshot_sha256 = NEW.dataset_snapshot_sha256
    AND snapshot.snapshot_kind = 'DETECTION_DATASET'
    AND snapshot.state = 'READY';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'rule_run_requires_ready_detection_snapshot'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION core.assert_v2_rule_run_snapshot() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.assert_v2_rule_run_snapshot() FROM PUBLIC;
CREATE TRIGGER rule_runs_v2_snapshot_guard
  BEFORE INSERT OR UPDATE OF dataset_snapshot_id, dataset_snapshot_sha256
  ON core.rule_runs
  FOR EACH ROW EXECUTE FUNCTION core.assert_v2_rule_run_snapshot();

CREATE OR REPLACE FUNCTION ops.assert_v2_agent_run_snapshot()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, pg_temp
AS $$
BEGIN
  IF NEW.run_contract_version = 1 THEN
    RETURN NEW;
  END IF;
  PERFORM 1
  FROM core.dataset_snapshots AS snapshot
  WHERE snapshot.id = NEW.dataset_snapshot_id
    AND snapshot.snapshot_sha256 = NEW.input_snapshot_hash
    AND snapshot.snapshot_kind = 'AGENT_CASE'
    AND snapshot.state = 'READY';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agent_run_requires_ready_case_snapshot'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.assert_v2_agent_run_snapshot() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.assert_v2_agent_run_snapshot() FROM PUBLIC;
CREATE TRIGGER agent_runs_v2_snapshot_guard
  BEFORE INSERT OR UPDATE OF run_contract_version, dataset_snapshot_id,
    input_snapshot_hash
  ON ops.agent_runs
  FOR EACH ROW EXECUTE FUNCTION ops.assert_v2_agent_run_snapshot();

-- R6b expands the closed tool contract from nine to thirteen rows.  Existing
-- pins remain byte-for-byte compatible except the active language-check
-- request schema, whose policy digest is now part of the request contract.
CREATE OR REPLACE FUNCTION ops.agent_tool_schema_contract_is_valid(
  p_tool_id text,
  p_request_sha256 char(64),
  p_response_sha256 char(64)
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT (p_tool_id, btrim(p_request_sha256), btrim(p_response_sha256)) IN (
    ('agency.profile',
     '32fcac51ce943f4ca5aeaeda5996958a601f2cd89ffb76498c06260d93e67230',
     '400480d8fc62033edb35c75a9b3d3eb0d87822b5d0bcccf24de61d8844c9ca55'),
    ('claim.language_check',
     '5f997b0ad29c80151e0ddd649f6763f14451b41dd8e653ffbf43eccf2ec0112e',
     'ac77f413e976813197b57db66a5737178c87f51ba7d67b19bc31aa80b7c0dbf6'),
    ('contract.find_comparables',
     '84fc62d88f8c6d61717fcf7e025cc4e7b4825703cb147d207ba6a92d8875a5c0',
     '15f512d7b8d1ddb98c09e04ece72c0907e29c21a38501bb539d86e43881e64fe'),
    ('contract.search',
     '53023a69e4f010bb1a50868e9da42601b3c71e8c8a2b6c4976574b8512019721',
     '334a5b481f5e8bbe5d52b0c4ea50be5d6d4fadcc08576318513312a7a80076e6'),
    ('entity.lookup',
     '19133149878dbbf54ef7865f1822c77ea2c31aac8bcfcc377ad4869e18bb713d',
     '0dc88f3b5cac41877326f3f6cbf5a86a8859e4124bdc387adc7816c3444256a1'),
    ('evidence.read',
     '71ba7e5b3d0867e7ac36354f82d42cf8533c1ed93b49426f248cc9147a6b8bde',
     'ec19aa983c3c786da78f4e2bc41e6398c6af24ae8d3506ee4cf0848a4a0fa4e0'),
    ('evidence.search',
     'd92f236d62ab15ddb3ba12af5f63079e2293057d7d5d21f5d43280306ca54c42',
     'cc44ee052c404fae5fd5945e483d60966e76b1f44c1ebfea576b19444bc651ca'),
    ('relationship.neighbors',
     '9f0443d480d37d32dd1de1b861730a3d0fa7a3cab5a1bb9a9add1cfef0b2b4e3',
     '3486871d493be124039b6ae170aa1a33854645ec63abc735d26dc12c49f245b9'),
    ('response.read',
     '87e0332aed2c7de8f604db95a629159856426e3f8e4f2649194c5148716d74ee',
     'f751a34a8f78407894ff96605241928d3fecee2f7ff9b48ba130ecb48701855f'),
    ('rule.reproduce',
     'ba0e45b6c03dad44a99299fc5a06058e740500dabe60f6af13cc77ebc5fd4147',
     '8104f45d77b0d576e986844e09b34370c642042ebe8d7c8a8dc3d68fbf9b21ff'),
    ('source.fetch',
     '8a6083ee948e416f71d7ee7e34ddb6ca41e84a8e3a2d1be53c4900605dc80c67',
     '42e59f2ddbe8bf2c58e61451cd698e388463f42bcdc13394bb6bf5140ca5912e'),
    ('source.locator_verify',
     '3470624bf89ed5d2116d7ef365b4dd017e822736f5b8d71189c7312653a5512f',
     'd8ddd0649eb49c0f0d8bc9490fb48134cb383cfa671d53d6ad710be39bd998ad'),
    ('supplier.profile',
     '0ecb53a68a6a0eff29ec4b1e56b0061859e8f9b8750a3e2f50be5a96686e870c',
     'e502989a7d06ee5dd7ae73d69b1822fd5dd4bc89c65b6b17553b37193b7149a3')
  )
$$;
ALTER FUNCTION ops.agent_tool_schema_contract_is_valid(text,char(64),char(64))
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.agent_tool_schema_contract_is_valid(text,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  ops.agent_tool_schema_contract_is_valid(text,char(64),char(64))
  TO gurine_analysis_worker;

CREATE OR REPLACE FUNCTION ops.agent_tool_payload_is_valid(
  p_tool_id text,
  p_request jsonb,
  p_result jsonb
) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT p_request IS NOT NULL
    AND jsonb_typeof(p_request) = 'object'
    AND CASE p_tool_id
      WHEN 'agency.profile' THEN
        p_request->>'schemaVersion' = 'agency.profile.request.v2'
      WHEN 'claim.language_check' THEN
        p_request->>'schemaVersion' = 'claim.language_check.request.v2'
      WHEN 'contract.find_comparables' THEN
        p_request->>'schemaVersion' = 'contract.find_comparables.request.v2'
      WHEN 'contract.search' THEN
        p_request->>'schemaVersion' = 'contract.search.request.v2'
      WHEN 'entity.lookup' THEN
        p_request->>'schemaVersion' = 'entity.lookup.request.v2'
      WHEN 'evidence.read' THEN
        p_request->>'schemaVersion' = 'evidence.read.request.v2'
      WHEN 'evidence.search' THEN
        p_request->>'schemaVersion' = 'evidence.search.request.v2'
      WHEN 'relationship.neighbors' THEN
        p_request->>'schemaVersion' = 'relationship.neighbors.request.v2'
      WHEN 'response.read' THEN
        p_request->>'schemaVersion' = 'response.read.request.v2'
      WHEN 'rule.reproduce' THEN
        p_request->>'schemaVersion' = 'rule.reproduce.request.v2'
      WHEN 'source.fetch' THEN true
      WHEN 'source.locator_verify' THEN
        p_request->>'schemaVersion' = 'source.locator_verify.request.v2'
      WHEN 'supplier.profile' THEN
        p_request->>'schemaVersion' = 'supplier.profile.request.v2'
      ELSE false
    END
    AND (
      p_result IS NULL
      OR (
        jsonb_typeof(p_result) = 'object'
        AND p_result->>'schemaVersion' = CASE p_tool_id
          WHEN 'agency.profile' THEN 'agency.profile.response.v2'
          WHEN 'claim.language_check' THEN 'claim.language_check.response.v2'
          WHEN 'contract.find_comparables' THEN
            'contract.find_comparables.response.v2'
          WHEN 'contract.search' THEN 'contract.search.response.v2'
          WHEN 'entity.lookup' THEN 'entity.lookup.response.v2'
          WHEN 'evidence.read' THEN 'evidence.read.response.v2'
          WHEN 'evidence.search' THEN 'evidence.search.response.v2'
          WHEN 'relationship.neighbors' THEN
            'relationship.neighbors.response.v2'
          WHEN 'response.read' THEN 'response.read.response.v2'
          WHEN 'rule.reproduce' THEN 'rule.reproduce.response.v2'
          WHEN 'source.fetch' THEN 'source.fetch.response.v2'
          WHEN 'source.locator_verify' THEN
            'source.locator_verify.response.v2'
          WHEN 'supplier.profile' THEN 'supplier.profile.response.v2'
          ELSE NULL
        END
      )
    )
$$;
ALTER FUNCTION ops.agent_tool_payload_is_valid(text,jsonb,jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.agent_tool_payload_is_valid(text,jsonb,jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.agent_tool_payload_is_valid(text,jsonb,jsonb)
  TO gurine_analysis_worker;

ALTER TABLE ops.agent_tool_calls DROP CONSTRAINT agent_tool_calls_tool_ck;
ALTER TABLE ops.agent_tool_calls ADD CONSTRAINT agent_tool_calls_tool_ck CHECK (
  tool_id IN (
    'agency.profile', 'claim.language_check', 'contract.find_comparables',
    'contract.search', 'entity.lookup', 'evidence.read', 'evidence.search',
    'relationship.neighbors', 'response.read', 'rule.reproduce',
    'source.fetch', 'source.locator_verify', 'supplier.profile'
  )
);

CREATE OR REPLACE FUNCTION ops.assert_v2_corpus_tool_snapshot()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, pg_temp
AS $$
DECLARE
  v_snapshot_id uuid;
  v_snapshot_sha256 char(64);
BEGIN
  IF NEW.tool_id NOT IN (
    'agency.profile', 'contract.search',
    'relationship.neighbors', 'supplier.profile'
  ) THEN
    RETURN NEW;
  END IF;
  SELECT run.dataset_snapshot_id, run.input_snapshot_hash
  INTO v_snapshot_id, v_snapshot_sha256
  FROM ops.agent_runs AS run
  JOIN core.dataset_snapshots AS snapshot
    ON snapshot.id = run.dataset_snapshot_id
   AND snapshot.snapshot_sha256 = run.input_snapshot_hash
  WHERE run.id = NEW.agent_run_id
    AND run.run_contract_version = 2
    AND snapshot.snapshot_kind = 'AGENT_CASE'
    AND snapshot.state = 'READY'
  FOR SHARE OF run, snapshot;
  IF NOT FOUND
     OR NEW.input_snapshot_sha256 <> v_snapshot_sha256
     OR NEW.request_redacted->>'runId' <> NEW.agent_run_id::text
     OR NEW.request_redacted->>'inputSnapshotId' <> v_snapshot_id::text
     OR NEW.request_redacted->>'inputSnapshotSha256' <>
       btrim(v_snapshot_sha256) THEN
    RAISE EXCEPTION 'corpus_tool_requires_exact_ready_snapshot'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.assert_v2_corpus_tool_snapshot() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.assert_v2_corpus_tool_snapshot() FROM PUBLIC;
CREATE TRIGGER agent_tool_calls_v2_corpus_snapshot_guard
  BEFORE INSERT OR UPDATE OF agent_run_id, input_snapshot_sha256,
    tool_id, request_redacted
  ON ops.agent_tool_calls
  FOR EACH ROW EXECUTE FUNCTION ops.assert_v2_corpus_tool_snapshot();

CREATE OR REPLACE FUNCTION core.guard_proven_supplier_identifier()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' AND OLD.proof_state = 'PROVEN_V1' THEN
    RAISE EXCEPTION 'proven_supplier_identifier_is_immutable'
      USING ERRCODE = '55000';
  END IF;
  IF TG_OP = 'UPDATE'
     AND (OLD.proof_state = 'PROVEN_V1' OR NEW.proof_state = 'PROVEN_V1') THEN
    RAISE EXCEPTION 'proven_supplier_identifier_is_immutable'
      USING ERRCODE = '55000';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION core.guard_proven_supplier_identifier() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.guard_proven_supplier_identifier() FROM PUBLIC;
CREATE TRIGGER supplier_identifiers_proven_immutable_guard
  BEFORE UPDATE OR DELETE ON core.supplier_identifiers
  FOR EACH ROW EXECUTE FUNCTION core.guard_proven_supplier_identifier();

CREATE OR REPLACE FUNCTION core.begin_dataset_snapshot(
  p_snapshot_kind text,
  p_producer_job_id uuid,
  p_producer_key text,
  p_producer_digest char(64),
  p_schema_version text,
  p_selection_spec jsonb,
  p_selection_canonical bytea,
  p_source_watermarks jsonb,
  p_source_watermarks_canonical bytea,
  p_normalization_versions jsonb,
  p_normalization_versions_canonical bytea,
  p_build_request_sha256 char(64),
  p_build_started_audit_event_id uuid
) RETURNS TABLE(
  snapshot_id uuid,
  producer_generation bigint,
  state text,
  snapshot_sha256 char(64),
  reused boolean
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, extensions, pg_temp
AS $$
DECLARE
  v_existing core.dataset_snapshots%ROWTYPE;
  v_generation bigint;
  v_snapshot_id uuid;
BEGIN
  IF p_snapshot_kind NOT IN ('AGENT_CASE', 'DETECTION_DATASET')
     OR p_producer_job_id IS NULL
     OR nullif(btrim(p_producer_key), '') IS NULL
     OR p_producer_digest !~ '^[0-9a-f]{64}$'
     OR nullif(btrim(p_schema_version), '') IS NULL
     OR p_selection_spec IS NULL
     OR p_source_watermarks IS NULL
     OR p_normalization_versions IS NULL
     OR p_build_request_sha256 !~ '^[0-9a-f]{64}$'
     OR p_build_started_audit_event_id IS NULL THEN
    RAISE EXCEPTION 'invalid_dataset_snapshot_begin'
      USING ERRCODE = '22023';
  END IF;
  IF p_selection_canonical <> ops.canonical_jsonb_v1(p_selection_spec)
     OR p_source_watermarks_canonical <>
       ops.canonical_jsonb_v1(p_source_watermarks)
     OR p_normalization_versions_canonical <>
       ops.canonical_jsonb_v1(p_normalization_versions) THEN
    RAISE EXCEPTION 'dataset_snapshot_canonical_mismatch'
      USING ERRCODE = '22023';
  END IF;
  -- Both producer-key and producer-digest generations are unique.  Lock the
  -- two allocation domains in numeric order so different keys sharing one
  -- implementation digest, or one key changing digests, cannot race into the
  -- same generation or deadlock each other.
  PERFORM pg_advisory_xact_lock(lock_key)
  FROM (
    SELECT DISTINCT lock_key
    FROM unnest(ARRAY[
      hashtextextended(
        'DATASET_SNAPSHOT:KEY:' || p_snapshot_kind || ':' || p_producer_key,
        0
      ),
      hashtextextended(
        'DATASET_SNAPSHOT:DIGEST:' || p_snapshot_kind || ':' ||
          btrim(p_producer_digest),
        0
      )
    ]) AS candidate(lock_key)
  ) AS locks
  ORDER BY lock_key;
  SELECT * INTO v_existing
  FROM core.dataset_snapshots AS snapshot
  WHERE snapshot.snapshot_kind = p_snapshot_kind
    AND snapshot.producer_key = p_producer_key
    AND snapshot.build_request_sha256 = p_build_request_sha256
    AND snapshot.state IN ('BUILDING', 'READY')
  ORDER BY snapshot.producer_generation DESC
  LIMIT 1
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.build_started_audit_event_id <>
       p_build_started_audit_event_id THEN
      RAISE EXCEPTION 'dataset_snapshot_replay_audit_mismatch'
        USING ERRCODE = '23514';
    END IF;
    RETURN QUERY SELECT
      v_existing.id, v_existing.producer_generation, v_existing.state,
      v_existing.snapshot_sha256, true;
    RETURN;
  END IF;
  SELECT nullif(audit.details->>'snapshotId', '')::uuid
  INTO v_snapshot_id
  FROM ops.audit_events AS audit
  WHERE audit.id = p_build_started_audit_event_id
    AND audit.actor_type = 'SERVICE'
    AND audit.actor_id = 'analysis-worker'
    AND audit.action = 'DATASET_SNAPSHOT_BUILD_STARTED'
    AND audit.object_type = 'DatasetSnapshot'
    AND audit.object_id = audit.details->>'snapshotId'
    AND audit.capability = 'jobs.operate'
    AND audit.outcome = 'SUCCESS'
    AND audit.request_id = p_producer_job_id
    AND audit.details->>'snapshotKind' = p_snapshot_kind
    AND audit.details->>'producerJobId' = p_producer_job_id::text
    AND audit.details->>'buildRequestSha256' = btrim(p_build_request_sha256);
  IF v_snapshot_id IS NULL THEN
    RAISE EXCEPTION 'dataset_snapshot_build_audit_binding_invalid'
      USING ERRCODE = '23514';
  END IF;
  SELECT COALESCE(max(snapshot.producer_generation), 0) + 1
  INTO v_generation
  FROM core.dataset_snapshots AS snapshot
  WHERE snapshot.snapshot_kind = p_snapshot_kind
    AND (
      snapshot.producer_key = p_producer_key
      OR snapshot.producer_digest = p_producer_digest
    );

  INSERT INTO core.dataset_snapshots(
    id, snapshot_kind, producer_component, producer_job_id, producer_key,
    producer_digest, producer_generation, schema_version, selection_spec,
    selection_canonical, selection_sha256, source_watermarks,
    source_watermarks_canonical, source_watermark_sha256,
    normalization_versions, normalization_versions_canonical,
    normalization_set_sha256, build_request_sha256,
    build_started_audit_event_id
  ) VALUES (
    v_snapshot_id, p_snapshot_kind, 'snapshot-producer', p_producer_job_id,
    p_producer_key, p_producer_digest, v_generation, p_schema_version,
    p_selection_spec, p_selection_canonical,
    encode(extensions.digest(p_selection_canonical, 'sha256'), 'hex'),
    p_source_watermarks, p_source_watermarks_canonical,
    encode(extensions.digest(p_source_watermarks_canonical, 'sha256'), 'hex'),
    p_normalization_versions, p_normalization_versions_canonical,
    encode(
      extensions.digest(p_normalization_versions_canonical, 'sha256'), 'hex'
    ),
    p_build_request_sha256, p_build_started_audit_event_id
  );
  RETURN QUERY SELECT v_snapshot_id, v_generation, 'BUILDING'::text,
    NULL::char(64), false;
END
$$;
ALTER FUNCTION core.begin_dataset_snapshot(
  text,uuid,text,char(64),text,jsonb,bytea,jsonb,bytea,jsonb,bytea,
  char(64),uuid
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.begin_dataset_snapshot(
  text,uuid,text,char(64),text,jsonb,bytea,jsonb,bytea,jsonb,bytea,
  char(64),uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.begin_dataset_snapshot(
  text,uuid,text,char(64),text,jsonb,bytea,jsonb,bytea,jsonb,bytea,
  char(64),uuid
) TO gurine_analysis_worker;

CREATE OR REPLACE FUNCTION core.finalize_dataset_snapshot(
  p_snapshot_id uuid,
  p_expected_version bigint,
  p_terminal_state text,
  p_member_count bigint,
  p_member_set_sha256 char(64),
  p_snapshot_manifest jsonb,
  p_snapshot_manifest_canonical bytea,
  p_terminal_receipt_sha256 char(64),
  p_terminal_audit_event_id uuid,
  p_error_code text,
  p_error_sha256 char(64)
) RETURNS TABLE(
  snapshot_id uuid,
  state text,
  version bigint,
  snapshot_sha256 char(64),
  member_count bigint
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, extensions, pg_temp
AS $$
DECLARE
  v_snapshot core.dataset_snapshots%ROWTYPE;
  v_actual_count bigint;
  v_actual_set_sha256 char(64);
  v_snapshot_sha256 char(64);
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_snapshot_id IS NULL OR p_expected_version < 1
     OR p_terminal_state NOT IN ('READY', 'FAILED')
     OR p_member_count < 0
     OR p_terminal_receipt_sha256 !~ '^[0-9a-f]{64}$'
     OR p_terminal_audit_event_id IS NULL THEN
    RAISE EXCEPTION 'invalid_dataset_snapshot_finalization'
      USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_snapshot
  FROM core.dataset_snapshots AS snapshot
  WHERE snapshot.id = p_snapshot_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'dataset_snapshot_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_snapshot.state IN ('READY', 'FAILED') THEN
    IF v_snapshot.version = p_expected_version + 1
       AND v_snapshot.state = p_terminal_state
       AND v_snapshot.member_count = p_member_count
       AND v_snapshot.terminal_receipt_sha256 = p_terminal_receipt_sha256
       AND v_snapshot.terminal_audit_event_id = p_terminal_audit_event_id
       AND (
         (
           p_terminal_state = 'READY'
           AND v_snapshot.member_set_sha256 = p_member_set_sha256
           AND v_snapshot.snapshot_manifest = p_snapshot_manifest
           AND v_snapshot.snapshot_manifest_canonical =
             p_snapshot_manifest_canonical
           AND v_snapshot.error_code IS NULL
           AND v_snapshot.error_sha256 IS NULL
         )
         OR (
           p_terminal_state = 'FAILED'
           AND p_member_set_sha256 IS NULL
           AND p_snapshot_manifest IS NULL
           AND p_snapshot_manifest_canonical IS NULL
           AND v_snapshot.error_code = p_error_code
           AND v_snapshot.error_sha256 = p_error_sha256
         )
       ) THEN
      RETURN QUERY SELECT
        v_snapshot.id, v_snapshot.state, v_snapshot.version,
        v_snapshot.snapshot_sha256, v_snapshot.member_count;
      RETURN;
    END IF;
    RAISE EXCEPTION 'dataset_snapshot_finalization_replay_conflict'
      USING ERRCODE = '40001';
  END IF;
  IF v_snapshot.state <> 'BUILDING'
     OR v_snapshot.version <> p_expected_version THEN
    RAISE EXCEPTION 'dataset_snapshot_finalization_fence_stale'
      USING ERRCODE = '40001';
  END IF;
  PERFORM 1
  FROM ops.audit_events AS audit
  WHERE audit.id = p_terminal_audit_event_id
    AND audit.actor_type = 'SERVICE'
    AND (
      audit.actor_id = 'analysis-worker'
      OR (
        v_snapshot.snapshot_kind = 'AGENT_CASE'
        AND audit.actor_id = 'workflow-worker'
        AND v_snapshot.producer_key =
          'auto-signal:' || audit.request_id::text
        AND EXISTS (
          SELECT 1
          FROM ops.audit_events AS build_audit
          WHERE build_audit.id = v_snapshot.build_started_audit_event_id
            AND build_audit.actor_type = 'SERVICE'
            AND build_audit.actor_id = 'workflow-worker'
            AND build_audit.action = 'DATASET_SNAPSHOT_BUILD_STARTED'
            AND build_audit.object_type = 'DatasetSnapshot'
            AND build_audit.object_id = p_snapshot_id::text
            AND build_audit.capability = 'jobs.operate'
            AND build_audit.outcome = 'SUCCESS'
            AND build_audit.request_id = audit.request_id
            AND build_audit.details->>'snapshotId' = p_snapshot_id::text
            AND build_audit.details->>'snapshotKind' = 'AGENT_CASE'
            AND build_audit.details->>'producerJobId' =
              v_snapshot.producer_job_id::text
            AND build_audit.details->>'buildRequestSha256' =
              btrim(v_snapshot.build_request_sha256)
            AND build_audit.details ? 'sourceSnapshotId'
        )
      )
    )
    AND audit.action = CASE p_terminal_state
      WHEN 'READY' THEN 'DATASET_SNAPSHOT_READY'
      ELSE 'DATASET_SNAPSHOT_FAILED'
    END
    AND audit.object_type = 'DatasetSnapshot'
    AND audit.object_id = p_snapshot_id::text
    AND audit.capability = 'jobs.operate'
    AND audit.outcome = CASE p_terminal_state
      WHEN 'READY' THEN 'SUCCESS'::ops.audit_outcome
      ELSE 'FAILED'::ops.audit_outcome
    END
    AND audit.details->>'snapshotId' = p_snapshot_id::text
    AND audit.details->>'state' = p_terminal_state
    AND audit.details->>'terminalReceiptDigest' =
      btrim(p_terminal_receipt_sha256);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'dataset_snapshot_terminal_audit_binding_invalid'
      USING ERRCODE = '23514';
  END IF;

  SELECT count(*) INTO v_actual_count
  FROM core.dataset_snapshot_members AS member
  WHERE member.dataset_snapshot_id = p_snapshot_id;

  IF p_terminal_state = 'READY' THEN
    IF p_member_set_sha256 !~ '^[0-9a-f]{64}$'
       OR p_snapshot_manifest IS NULL
       OR p_snapshot_manifest_canonical IS NULL
       OR p_error_code IS NOT NULL OR p_error_sha256 IS NOT NULL
       OR p_snapshot_manifest_canonical <>
         ops.canonical_jsonb_v1(p_snapshot_manifest) THEN
      RAISE EXCEPTION 'invalid_ready_snapshot_shape' USING ERRCODE = '22023';
    END IF;
    IF p_snapshot_manifest <> jsonb_build_object(
      'schemaVersion', 'dataset-snapshot-manifest.v1',
      'snapshotId', p_snapshot_id,
      'snapshotKind', v_snapshot.snapshot_kind,
      'producerDigest', btrim(v_snapshot.producer_digest),
      'producerGeneration', v_snapshot.producer_generation,
      'selectionSha256', btrim(v_snapshot.selection_sha256),
      'sourceWatermarkSha256', btrim(v_snapshot.source_watermark_sha256),
      'normalizationSetSha256', btrim(v_snapshot.normalization_set_sha256),
      'memberCount', p_member_count,
      'memberSetSha256', btrim(p_member_set_sha256)
    ) THEN
      RAISE EXCEPTION 'dataset_snapshot_manifest_binding_mismatch'
        USING ERRCODE = '23514';
    END IF;
    IF v_actual_count <> p_member_count THEN
      RAISE EXCEPTION 'dataset_snapshot_member_count_mismatch'
        USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM core.dataset_snapshot_members AS member
      WHERE member.dataset_snapshot_id = p_snapshot_id
        AND (
          member.member_ordinal < 0
          OR member.payload_sha256 <>
            encode(
              extensions.digest(member.canonical_payload_bytes, 'sha256'),
              'hex'
            )
          OR member.member_digest <>
            encode(
              extensions.digest(member.member_binding_canonical, 'sha256'),
              'hex'
            )
          OR member.source_count <> (
            SELECT count(*)
            FROM core.dataset_snapshot_member_sources AS source
            WHERE source.snapshot_member_id = member.id
          )
          OR member.source_set_sha256 <> (
            SELECT encode(
              extensions.digest(
                ops.canonical_jsonb_v1(
                  COALESCE(
                    jsonb_agg(source.source_digest ORDER BY source.source_ordinal),
                    '[]'::jsonb
                  )
                ), 'sha256'
              ), 'hex'
            )
            FROM core.dataset_snapshot_member_sources AS source
            WHERE source.snapshot_member_id = member.id
          )
          OR EXISTS (
            SELECT 1
            FROM core.dataset_snapshot_member_sources AS source
            WHERE source.snapshot_member_id = member.id
              AND source.source_ordinal <> (
                SELECT count(*) - 1
                FROM core.dataset_snapshot_member_sources AS preceding
                WHERE preceding.snapshot_member_id = member.id
                  AND preceding.source_ordinal <= source.source_ordinal
              )
          )
        )
    ) OR EXISTS (
      SELECT 1
      FROM core.dataset_snapshot_members AS member
      WHERE member.dataset_snapshot_id = p_snapshot_id
        AND member.member_ordinal <> (
          SELECT count(*) - 1
          FROM core.dataset_snapshot_members AS preceding
          WHERE preceding.dataset_snapshot_id = p_snapshot_id
            AND preceding.member_ordinal <= member.member_ordinal
        )
    ) THEN
      RAISE EXCEPTION 'dataset_snapshot_child_integrity_mismatch'
        USING ERRCODE = '23514';
    END IF;
    SELECT encode(
      extensions.digest(
        ops.canonical_jsonb_v1(
          COALESCE(
            jsonb_agg(member.member_digest ORDER BY member.member_ordinal),
            '[]'::jsonb
          )
        ), 'sha256'
      ), 'hex'
    ) INTO v_actual_set_sha256
    FROM core.dataset_snapshot_members AS member
    WHERE member.dataset_snapshot_id = p_snapshot_id;
    IF v_actual_set_sha256 <> p_member_set_sha256 THEN
      RAISE EXCEPTION 'dataset_snapshot_member_digest_mismatch'
        USING ERRCODE = '23514';
    END IF;
    v_snapshot_sha256 := encode(
      extensions.digest(p_snapshot_manifest_canonical, 'sha256'), 'hex'
    );
    UPDATE core.dataset_snapshots AS snapshot
    SET state = 'READY', member_count = p_member_count,
        member_set_sha256 = p_member_set_sha256,
        snapshot_manifest = p_snapshot_manifest,
        snapshot_manifest_canonical = p_snapshot_manifest_canonical,
        snapshot_sha256 = v_snapshot_sha256,
        terminal_receipt_sha256 = p_terminal_receipt_sha256,
        terminal_audit_event_id = p_terminal_audit_event_id,
        version = snapshot.version + 1, ready_at = v_now
    WHERE snapshot.id = p_snapshot_id;
  ELSE
    IF v_actual_count <> 0 OR p_member_count <> 0
       OR p_member_set_sha256 IS NOT NULL
       OR p_snapshot_manifest IS NOT NULL
       OR p_snapshot_manifest_canonical IS NOT NULL
       OR nullif(btrim(p_error_code), '') IS NULL
       OR p_error_sha256 !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'invalid_failed_snapshot_shape' USING ERRCODE = '22023';
    END IF;
    UPDATE core.dataset_snapshots AS snapshot
    SET state = 'FAILED', member_count = 0,
        terminal_receipt_sha256 = p_terminal_receipt_sha256,
        terminal_audit_event_id = p_terminal_audit_event_id,
        error_code = p_error_code, error_sha256 = p_error_sha256,
        version = snapshot.version + 1, failed_at = v_now
    WHERE snapshot.id = p_snapshot_id;
  END IF;

  PERFORM ops.enqueue_outbox(
    'DatasetSnapshot', p_snapshot_id::text, p_expected_version + 1,
    'dataset.snapshot_created.v1',
    jsonb_build_object(
      'snapshotId', p_snapshot_id,
      'snapshotKind', v_snapshot.snapshot_kind,
      'producerComponent', v_snapshot.producer_component,
      'producerDigest', v_snapshot.producer_digest,
      'producerGeneration', v_snapshot.producer_generation,
      'projectionWatermark', NULL,
      'memberCount', p_member_count,
      'sourceWatermarkDigest', v_snapshot.source_watermark_sha256,
      'state', p_terminal_state,
      'terminalReceiptDigest', p_terminal_receipt_sha256,
      'snapshotSha256', v_snapshot_sha256,
      'errorCode', p_error_code,
      'errorDigest', p_error_sha256,
      'occurredAt', v_now
    ), v_now
  );
  RETURN QUERY SELECT p_snapshot_id, p_terminal_state,
    p_expected_version + 1, v_snapshot_sha256, p_member_count;
END
$$;
ALTER FUNCTION core.finalize_dataset_snapshot(
  uuid,bigint,text,bigint,char(64),jsonb,bytea,char(64),uuid,text,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.finalize_dataset_snapshot(
  uuid,bigint,text,bigint,char(64),jsonb,bytea,char(64),uuid,text,char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.finalize_dataset_snapshot(
  uuid,bigint,text,bigint,char(64),jsonb,bytea,char(64),uuid,text,char(64)
) TO gurine_analysis_worker;

UPDATE ops.event_types
SET payload_schema = $event_schema$
{
  "additionalProperties": false,
  "type": "object",
  "properties": {
    "snapshotId": {"format": "uuid", "type": "string"},
    "snapshotKind": {"minLength": 1, "type": "string"},
    "producerComponent": {"minLength": 1, "type": "string"},
    "producerDigest": {"pattern": "^[0-9a-f]{64}$", "type": "string"},
    "producerGeneration": {"minimum": 1, "type": "integer"},
    "projectionWatermark": {
      "anyOf": [{"minimum": 0, "type": "integer"}, {"type": "null"}]
    },
    "memberCount": {"minimum": 0, "type": "integer"},
    "sourceWatermarkDigest": {
      "pattern": "^[0-9a-f]{64}$", "type": "string"
    },
    "state": {"enum": ["READY", "FAILED"], "type": "string"},
    "terminalReceiptDigest": {
      "pattern": "^[0-9a-f]{64}$", "type": "string"
    },
    "snapshotSha256": {
      "anyOf": [
        {"pattern": "^[0-9a-f]{64}$", "type": "string"},
        {"type": "null"}
      ]
    },
    "errorCode": {
      "anyOf": [{"minLength": 1, "type": "string"}, {"type": "null"}]
    },
    "errorDigest": {
      "anyOf": [
        {"pattern": "^[0-9a-f]{64}$", "type": "string"},
        {"type": "null"}
      ]
    },
    "occurredAt": {"format": "date-time", "type": "string"}
  },
  "required": [
    "snapshotId", "snapshotKind", "producerComponent", "producerDigest",
    "producerGeneration", "projectionWatermark", "memberCount",
    "sourceWatermarkDigest", "state", "terminalReceiptDigest",
    "snapshotSha256", "errorCode", "errorDigest", "occurredAt"
  ]
}
$event_schema$::jsonb
WHERE event_type = 'dataset.snapshot_created.v1';

-- The declared candidate payload depends on an immutable mapping-activation
-- authority that is not physically available yet.  The only safe writer is a
-- closed, side-effect-free denial.  In particular, this routine does not
-- reinterpret retrieved_at as mappingEffectiveFrom and does not trust any
-- caller-supplied digest as activation evidence.
CREATE OR REPLACE FUNCTION core.record_supplier_identity_candidate_v1(
  p_request jsonb
) RETURNS TABLE(
  candidate_id uuid,
  merge_decision_id uuid,
  disposition text,
  recorded boolean
)
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT
    NULL::uuid,
    NULL::uuid,
    'MAPPING_ACTIVATION_MISSING'::text,
    false
  WHERE p_request IS NOT DISTINCT FROM p_request
$$;
ALTER FUNCTION core.record_supplier_identity_candidate_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.record_supplier_identity_candidate_v1(jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.record_supplier_identity_candidate_v1(jsonb)
  TO gurine_ingest_worker;

-- The signal owner routine inserts only one fenced v2 run and its matching
-- analysis job.  The runtime role receives no table DML; these are the narrow
-- privileges required by the SECURITY DEFINER owner itself.
GRANT INSERT ON ops.agent_runs TO gurine_migrator;
GRANT INSERT, UPDATE ON ops.jobs TO gurine_migrator;

-- A signal is consumed exactly once.  Every policy denial is a successful,
-- durable no-op; only STARTED creates a case/snapshot/run/job graph.  The
-- routine never changes signal/case publication state, accepts a suggestion,
-- or resolves an identity.
CREATE OR REPLACE FUNCTION ops.process_signal_investigation_v1(
  p_signal_id uuid,
  p_producer_job_id uuid
) RETURNS TABLE(
  disposition text,
  case_id uuid,
  dataset_snapshot_id uuid,
  agent_run_id uuid,
  job_id uuid,
  receipt_id uuid,
  actor_type text,
  actor_id text,
  replayed boolean
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, editorial, ops, extensions, pg_temp
AS $$
DECLARE
  v_signal core.anomaly_signals%ROWTYPE;
  v_policy ops.signal_investigation_policies%ROWTYPE;
  v_existing ops.signal_investigation_initiation_receipts%ROWTYPE;
  v_prior_started ops.signal_investigation_initiation_receipts%ROWTYPE;
  v_detection_snapshot core.dataset_snapshots%ROWTYPE;
  v_member record;
  v_source record;
  v_disposition text;
  v_case_id uuid;
  v_snapshot_id uuid;
  v_agent_run_id uuid;
  v_job_id uuid;
  v_receipt_id uuid := gen_random_uuid();
  v_audit_id uuid;
  v_now timestamptz := clock_timestamp();
  v_payload jsonb;
  v_canonical bytea;
  v_digest char(64);
  v_selection jsonb;
  v_selection_canonical bytea;
  v_producer_digest char(64);
  v_build_request_sha256 char(64);
  v_snapshot_generation bigint;
  v_snapshot_build_audit_id uuid;
  v_snapshot_terminal_audit_id uuid;
  v_snapshot_terminal_payload jsonb;
  v_snapshot_terminal_canonical bytea;
  v_snapshot_terminal_digest char(64);
  v_snapshot_manifest jsonb;
  v_snapshot_manifest_canonical bytea;
  v_snapshot_sha256 char(64);
  v_member_count bigint := 0;
  v_selected_member_count bigint;
  v_member_digests jsonb := '[]'::jsonb;
  v_member_set_sha256 char(64);
  v_new_member_id uuid;
  v_member_binding_canonical bytea;
  v_member_digest char(64);
  v_scope_id_count bigint;
  v_case_version bigint;
  v_initial_transcript_sha256 char(64);
BEGIN
  IF p_signal_id IS NULL OR p_producer_job_id IS NULL THEN
    RAISE EXCEPTION 'signal_investigation_input_invalid'
      USING ERRCODE = '22023';
  END IF;
  IF NOT pg_has_role(session_user, 'gurine_workflow_worker', 'MEMBER') THEN
    RAISE EXCEPTION 'signal_investigation_worker_role_required'
      USING ERRCODE = '42501';
  END IF;

  SELECT signal.* INTO v_signal
  FROM core.anomaly_signals AS signal
  WHERE signal.id = p_signal_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'signal_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT receipt.* INTO v_existing
  FROM ops.signal_investigation_initiation_receipts AS receipt
  WHERE receipt.signal_id = p_signal_id
  FOR SHARE;
  IF FOUND THEN
    RETURN QUERY SELECT
      v_existing.disposition, v_existing.case_id,
      v_existing.dataset_snapshot_id, v_existing.agent_run_id,
      v_existing.job_id, v_existing.receipt_id,
      v_existing.actor_type, v_existing.actor_id, true;
    RETURN;
  END IF;
  PERFORM 1 FROM ops.jobs AS producer_job
  WHERE producer_job.id = p_producer_job_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'signal_investigation_producer_job_not_found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('AUTO_SIGNAL_INVESTIGATION', 0)
  );
  SELECT policy.* INTO v_policy
  FROM ops.signal_investigation_policies AS policy
  WHERE policy.policy_key = 'AUTO_SIGNAL_INVESTIGATION'
  ORDER BY policy.version DESC, policy.policy_id DESC
  LIMIT 1
  FOR UPDATE;

  <<policy_evaluation>>
  BEGIN
    IF NOT FOUND THEN
      v_disposition := 'POLICY_ABSENT';
      EXIT policy_evaluation;
    END IF;
    IF NOT v_policy.enabled THEN
      v_disposition := 'POLICY_DISABLED';
      EXIT policy_evaluation;
    END IF;
    IF EXISTS (
      SELECT 1 FROM ops.kill_switches AS kill_switch
      WHERE kill_switch.state = 'ACTIVE'
        AND (kill_switch.expires_at IS NULL OR kill_switch.expires_at > v_now)
        AND (
          kill_switch.code = v_policy.kill_switch_code
          OR kill_switch.scope->>'code' = v_policy.kill_switch_code
          OR kill_switch.scope->>'killSwitchCode' = v_policy.kill_switch_code
        )
    ) THEN
      v_disposition := 'KILL_SWITCH_ACTIVE';
      EXIT policy_evaluation;
    END IF;
    IF (CASE v_signal.severity
          WHEN 'INFO' THEN 1 WHEN 'LOW' THEN 2 WHEN 'MEDIUM' THEN 3
          WHEN 'HIGH' THEN 4 WHEN 'CRITICAL' THEN 5 ELSE 0 END)
       < (CASE v_policy.minimum_severity
          WHEN 'INFO' THEN 1 WHEN 'LOW' THEN 2 WHEN 'MEDIUM' THEN 3
          WHEN 'HIGH' THEN 4 WHEN 'CRITICAL' THEN 5 ELSE 6 END) THEN
      v_disposition := 'BELOW_MIN_SEVERITY';
      EXIT policy_evaluation;
    END IF;
    IF EXISTS (
      SELECT 1
      FROM ops.signal_investigation_initiation_receipts AS prior
      WHERE prior.disposition = 'STARTED'
        AND prior.rule_version_id = v_signal.rule_version_id
        AND prior.target_type = v_signal.target_type
        AND prior.target_id = v_signal.target_id
        AND prior.created_at >= v_now - v_policy.dedupe_window
    ) THEN
      v_disposition := 'DUPLICATE_SUPPRESSED';
      EXIT policy_evaluation;
    END IF;
    SELECT prior.* INTO v_prior_started
    FROM ops.signal_investigation_initiation_receipts AS prior
    WHERE prior.disposition = 'STARTED'
      AND prior.target_type = v_signal.target_type
      AND prior.target_id = v_signal.target_id
    ORDER BY prior.created_at DESC, prior.receipt_id DESC
    LIMIT 1;
    IF FOUND THEN
      v_case_id := v_prior_started.case_id;
      SELECT current_case.version INTO v_case_version
      FROM editorial.cases AS current_case
      WHERE current_case.id = v_case_id
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'signal_investigation_prior_case_missing'
          USING ERRCODE = '40001';
      END IF;
    END IF;
    IF (
      SELECT count(*)
      FROM ops.signal_investigation_initiation_receipts AS started
      WHERE started.disposition = 'STARTED'
        AND started.created_at >= date_trunc('day', v_now)
    ) >= v_policy.daily_run_limit THEN
      v_disposition := 'DAILY_LIMIT_REACHED';
      EXIT policy_evaluation;
    END IF;
    IF v_case_id IS NOT NULL AND (
      SELECT count(*)
      FROM ops.signal_investigation_initiation_receipts AS started
      WHERE started.disposition = 'STARTED'
        AND started.case_id = v_case_id
        AND started.created_at >= date_trunc('day', v_now)
    ) >= v_policy.case_daily_run_limit THEN
      v_disposition := 'CASE_DAILY_LIMIT_REACHED';
      EXIT policy_evaluation;
    END IF;
    IF COALESCE((
      SELECT sum(started.reserved_micros_krw)
      FROM ops.signal_investigation_initiation_receipts AS started
      WHERE started.disposition = 'STARTED'
        AND started.created_at >= date_trunc('day', v_now)
    ), 0) + v_policy.max_run_micros_krw
       > v_policy.daily_budget_micros_krw THEN
      v_disposition := 'BUDGET_BLOCKED';
      EXIT policy_evaluation;
    END IF;
    IF v_policy.provider_classification NOT IN ('PUBLIC', 'INTERNAL')
       OR NOT EXISTS (
         SELECT 1
         FROM ops.provider_configs AS provider
         WHERE provider.enabled
           AND (
             lower(provider.provider_type) = ANY(v_policy.provider_candidate_ids)
             OR lower(provider.name) = ANY(v_policy.provider_candidate_ids)
           )
           AND provider.routing_policy#>>'{dataPolicy,state}' = 'CONFIGURED'
           AND nullif(btrim(provider.routing_policy->>'model'), '') IS NOT NULL
       ) THEN
      v_disposition := 'PROVIDER_UNAVAILABLE';
      EXIT policy_evaluation;
    END IF;
    SELECT snapshot.* INTO v_detection_snapshot
    FROM core.rule_runs AS run
    JOIN core.dataset_snapshots AS snapshot
      ON snapshot.id = run.dataset_snapshot_id
     AND snapshot.snapshot_sha256 = run.dataset_snapshot_sha256
    WHERE run.id = v_signal.rule_run_id
      AND run.rule_version_id = v_signal.rule_version_id
      AND snapshot.snapshot_kind = 'DETECTION_DATASET'
      AND snapshot.state = 'READY'
    FOR SHARE OF snapshot;
    IF NOT FOUND
       OR jsonb_typeof(v_signal.explanation->'includedIds')
         IS DISTINCT FROM 'array' THEN
      v_disposition := 'EVIDENCE_SCOPE_DENIED';
      EXIT policy_evaluation;
    END IF;
    IF jsonb_array_length(v_signal.explanation->'includedIds') = 0
       OR EXISTS (
         SELECT 1
         FROM jsonb_array_elements(v_signal.explanation->'includedIds') AS item(value)
         WHERE jsonb_typeof(item.value) <> 'string'
            OR item.value #>> '{}' !~*
              '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
       )
       OR EXISTS (
         SELECT 1
         FROM jsonb_array_elements_text(
           v_signal.explanation->'includedIds'
         ) AS item(value)
         GROUP BY item.value HAVING count(*) <> 1
       ) THEN
      v_disposition := 'EVIDENCE_SCOPE_DENIED';
      EXIT policy_evaluation;
    END IF;
    SELECT count(DISTINCT item.value) INTO v_scope_id_count
    FROM jsonb_array_elements_text(
      v_signal.explanation->'includedIds'
    ) AS item(value)
    WHERE EXISTS (
      SELECT 1 FROM core.dataset_snapshot_members AS member
      WHERE member.dataset_snapshot_id = v_detection_snapshot.id
        AND member.object_id = item.value::uuid
    );
    IF v_scope_id_count <> jsonb_array_length(
         v_signal.explanation->'includedIds'
       ) THEN
      v_disposition := 'EVIDENCE_SCOPE_DENIED';
      EXIT policy_evaluation;
    END IF;
    SELECT count(*) INTO v_selected_member_count
    FROM core.dataset_snapshot_members AS member
    WHERE member.dataset_snapshot_id = v_detection_snapshot.id
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(
          v_signal.explanation->'includedIds'
        ) AS item(value)
        WHERE item.value::uuid = member.object_id
      );
    IF v_selected_member_count <> jsonb_array_length(
         v_signal.explanation->'includedIds'
       ) THEN
      v_disposition := 'EVIDENCE_SCOPE_DENIED';
      EXIT policy_evaluation;
    END IF;
    v_disposition := 'STARTED';
  END policy_evaluation;

  IF v_disposition <> 'STARTED' THEN
    v_audit_id := ops.append_audit_event(
      'worker:signal-investigation:' || p_signal_id::text,
      'SERVICE', 'workflow-worker', NULL::uuid,
      'SIGNAL_INVESTIGATION_NOT_STARTED', 'Signal', p_signal_id::text,
      'jobs.operate', 'SUCCESS', v_disposition, p_signal_id,
      jsonb_build_object(
        'disposition', v_disposition,
        'policyId', CASE WHEN v_policy.policy_id IS NULL
          THEN NULL ELSE v_policy.policy_id END,
        'policyVersion', CASE WHEN v_policy.policy_id IS NULL
          THEN NULL ELSE v_policy.version END,
        'producerJobId', p_producer_job_id
      )
    );
    v_payload := jsonb_build_object(
      'schemaVersion', 'signal-investigation-initiation-receipt.v1',
      'receiptId', v_receipt_id, 'signalId', p_signal_id,
      'ruleVersionId', v_signal.rule_version_id,
      'targetType', v_signal.target_type, 'targetId', v_signal.target_id,
      'producerJobId', p_producer_job_id,
      'policyId', CASE WHEN v_policy.policy_id IS NULL
        THEN NULL ELSE v_policy.policy_id END,
      'policyVersion', CASE WHEN v_policy.policy_id IS NULL
        THEN NULL ELSE v_policy.version END,
      'disposition', v_disposition, 'reservedMicrosKrw', 0,
      'actorType', 'SERVICE', 'actorId', 'workflow-worker',
      'auditEventId', v_audit_id, 'occurredAt', v_now
    );
    v_canonical := ops.canonical_jsonb_v1(v_payload);
    v_digest := encode(extensions.digest(v_canonical, 'sha256'), 'hex');
    INSERT INTO ops.signal_investigation_initiation_receipts(
      receipt_id, signal_id, rule_version_id, target_type, target_id,
      producer_job_id, policy_id, policy_version, disposition,
      reserved_micros_krw, audit_event_id, receipt_payload,
      receipt_canonical, receipt_digest, created_at
    ) VALUES (
      v_receipt_id, p_signal_id, v_signal.rule_version_id,
      v_signal.target_type, v_signal.target_id, p_producer_job_id,
      v_policy.policy_id, v_policy.version, v_disposition, 0,
      v_audit_id, v_payload, v_canonical, v_digest, v_now
    );
    RETURN QUERY SELECT v_disposition, NULL::uuid, NULL::uuid, NULL::uuid,
      NULL::uuid, v_receipt_id, 'SERVICE'::text,
      'workflow-worker'::text, false;
    RETURN;
  END IF;

  IF v_case_id IS NULL THEN
    INSERT INTO editorial.cases(id, title, priority)
    VALUES (
      gen_random_uuid(),
      '자동 조사 · ' || v_signal.signal_type || ' · '
        || left(v_signal.target_id::text, 8),
      CASE v_signal.severity
        WHEN 'CRITICAL' THEN 'URGENT' WHEN 'HIGH' THEN 'HIGH'
        ELSE 'NORMAL' END
    ) RETURNING id, version INTO v_case_id, v_case_version;
  END IF;
  INSERT INTO editorial.case_signals(
    case_id, signal_id, link_reason, linked_by,
    linked_actor_type, linked_service
  ) VALUES (
    v_case_id, p_signal_id, 'AUTOMATIC_INVESTIGATION_SCOPE', NULL,
    'SERVICE', 'workflow-worker'
  ) ON CONFLICT ON CONSTRAINT case_signals_pkey DO NOTHING;

  v_snapshot_id := gen_random_uuid();
  v_selection := jsonb_build_object(
    'snapshotKind', 'AGENT_CASE', 'caseId', v_case_id,
    'caseVersion', v_case_version,
    'evidenceSegmentBindings', '[]'::jsonb,
    'responseBindings', '[]'::jsonb,
    'selectionPolicyVersion', 'automatic-signal-investigation-v1'
  );
  v_selection_canonical := ops.canonical_jsonb_v1(v_selection);
  v_producer_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'selectionSha256', encode(
        extensions.digest(v_selection_canonical, 'sha256'), 'hex'
      ),
      'sourceWatermarkSha256', v_detection_snapshot.source_watermark_sha256,
      'normalizationSetSha256', v_detection_snapshot.normalization_set_sha256
    )), 'sha256'
  ), 'hex');
  SELECT COALESCE(max(snapshot.producer_generation), 0) + 1
  INTO v_snapshot_generation
  FROM core.dataset_snapshots AS snapshot
  WHERE snapshot.snapshot_kind = 'AGENT_CASE'
    AND (
      snapshot.producer_key = 'auto-signal:' || p_signal_id::text
      OR snapshot.producer_digest = v_producer_digest
    );
  v_build_request_sha256 := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'snapshotId', v_snapshot_id, 'snapshotKind', 'AGENT_CASE',
      'producerKey', 'auto-signal:' || p_signal_id::text,
      'producerDigest', v_producer_digest,
      'producerGeneration', v_snapshot_generation,
      'sourceSnapshotId', v_detection_snapshot.id,
      'signalId', p_signal_id
    )), 'sha256'
  ), 'hex');
  v_snapshot_build_audit_id := ops.append_audit_event(
    'snapshot:' || v_snapshot_id::text, 'SERVICE', 'workflow-worker',
    NULL::uuid, 'DATASET_SNAPSHOT_BUILD_STARTED', 'DatasetSnapshot',
    v_snapshot_id::text, 'jobs.operate', 'SUCCESS', NULL, p_signal_id,
    jsonb_build_object(
      'snapshotId', v_snapshot_id, 'snapshotKind', 'AGENT_CASE',
      'producerJobId', p_producer_job_id,
      'buildRequestSha256', v_build_request_sha256,
      'sourceSnapshotId', v_detection_snapshot.id
    )
  );
  INSERT INTO core.dataset_snapshots(
    id, snapshot_kind, producer_component, producer_job_id, producer_key,
    producer_digest, producer_generation, schema_version, selection_spec,
    selection_canonical, selection_sha256, source_watermarks,
    source_watermarks_canonical, source_watermark_sha256,
    normalization_versions, normalization_versions_canonical,
    normalization_set_sha256, build_request_sha256,
    build_started_audit_event_id
  ) VALUES (
    v_snapshot_id, 'AGENT_CASE', 'snapshot-producer', p_producer_job_id,
    'auto-signal:' || p_signal_id::text, v_producer_digest,
    v_snapshot_generation, 'dataset-snapshot.v1', v_selection,
    v_selection_canonical,
    encode(extensions.digest(v_selection_canonical, 'sha256'), 'hex'),
    v_detection_snapshot.source_watermarks,
    v_detection_snapshot.source_watermarks_canonical,
    v_detection_snapshot.source_watermark_sha256,
    v_detection_snapshot.normalization_versions,
    v_detection_snapshot.normalization_versions_canonical,
    v_detection_snapshot.normalization_set_sha256,
    v_build_request_sha256, v_snapshot_build_audit_id
  );

  FOR v_member IN
    SELECT member.*
    FROM core.dataset_snapshot_members AS member
    WHERE member.dataset_snapshot_id = v_detection_snapshot.id
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(
          v_signal.explanation->'includedIds'
        ) AS item(value)
        WHERE item.value::uuid = member.object_id
      )
    ORDER BY member.member_ordinal
  LOOP
    v_new_member_id := gen_random_uuid();
    v_member_binding_canonical := ops.canonical_jsonb_v1(
      jsonb_build_object(
        'schemaVersion', 'dataset-snapshot-member-binding.v1',
        'snapshotId', v_snapshot_id,
        'snapshotMemberId', v_new_member_id,
        'snapshotKind', 'AGENT_CASE',
        'producerGeneration', v_snapshot_generation,
        'snapshotContractVersion', 1,
        'memberOrdinal', v_member_count,
        'objectType', v_member.object_type,
        'objectId', v_member.object_id,
        'objectVersion', v_member.object_version,
        'objectSchemaVersion', v_member.object_schema_version,
        'objectContentSha256', btrim(v_member.object_content_sha256::text),
        'payloadSha256', btrim(v_member.payload_sha256::text),
        'normalizationRunId', v_member.normalization_run_id,
        'normalizationVersion', v_member.normalization_version,
        'normalizationSha256', CASE
          WHEN v_member.normalization_sha256 IS NULL THEN NULL
          ELSE btrim(v_member.normalization_sha256::text) END,
        'evidenceSegmentId', v_member.evidence_segment_id,
        'responseId', v_member.response_id,
        'sourceCount', v_member.source_count,
        'sourceSetSha256', btrim(v_member.source_set_sha256::text)
      )
    );
    v_member_digest := encode(extensions.digest(
      v_member_binding_canonical, 'sha256'
    ), 'hex');
    INSERT INTO core.dataset_snapshot_members(
      id, dataset_snapshot_id, snapshot_kind, producer_generation,
      snapshot_contract_version, member_ordinal, object_type, object_id,
      object_version, object_schema_version, object_content_sha256,
      canonical_payload, canonical_payload_bytes, payload_sha256,
      normalization_run_id, normalization_version, normalization_sha256,
      evidence_segment_id, response_id, source_count, source_set_sha256,
      member_binding_canonical, member_digest
    ) VALUES (
      v_new_member_id, v_snapshot_id, 'AGENT_CASE', v_snapshot_generation,
      1, v_member_count, v_member.object_type, v_member.object_id,
      v_member.object_version, v_member.object_schema_version,
      v_member.object_content_sha256, v_member.canonical_payload,
      v_member.canonical_payload_bytes, v_member.payload_sha256,
      v_member.normalization_run_id, v_member.normalization_version,
      v_member.normalization_sha256, v_member.evidence_segment_id,
      v_member.response_id, v_member.source_count,
      v_member.source_set_sha256, v_member_binding_canonical,
      v_member_digest
    );
    FOR v_source IN
      SELECT source.*
      FROM core.dataset_snapshot_member_sources AS source
      WHERE source.snapshot_member_id = v_member.id
      ORDER BY source.source_ordinal
    LOOP
      INSERT INTO core.dataset_snapshot_member_sources(
        id, dataset_snapshot_id, snapshot_member_id, member_ordinal,
        snapshot_member_digest, source_ordinal, lineage_kind, source_kind,
        source_document_id, source_asset_id, source_asset_revision,
        source_content_sha256, response_id, response_version,
        response_content_sha256, parser_run_id, parsed_record_id,
        normalization_run_id, field_provenance_id, evidence_segment_id,
        locator_digest, source_digest
      ) VALUES (
        gen_random_uuid(), v_snapshot_id, v_new_member_id, v_member_count,
        v_member_digest, v_source.source_ordinal,
        v_source.lineage_kind, v_source.source_kind,
        v_source.source_document_id, v_source.source_asset_id,
        v_source.source_asset_revision, v_source.source_content_sha256,
        v_source.response_id, v_source.response_version,
        v_source.response_content_sha256, v_source.parser_run_id,
        v_source.parsed_record_id, v_source.normalization_run_id,
        v_source.field_provenance_id, v_source.evidence_segment_id,
        v_source.locator_digest, v_source.source_digest
      );
    END LOOP;
    v_member_digests := v_member_digests
      || jsonb_build_array(btrim(v_member_digest::text));
    v_member_count := v_member_count + 1;
  END LOOP;
  IF v_member_count = 0 OR v_member_count <> v_selected_member_count THEN
    RAISE EXCEPTION 'signal_investigation_scope_became_empty'
      USING ERRCODE = '40001';
  END IF;
  v_member_set_sha256 := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_member_digests), 'sha256'
  ), 'hex');
  v_snapshot_manifest := jsonb_build_object(
    'schemaVersion', 'dataset-snapshot-manifest.v1',
    'snapshotId', v_snapshot_id, 'snapshotKind', 'AGENT_CASE',
    'producerDigest', v_producer_digest,
    'producerGeneration', v_snapshot_generation,
    'selectionSha256', encode(
      extensions.digest(v_selection_canonical, 'sha256'), 'hex'
    ),
    'sourceWatermarkSha256', v_detection_snapshot.source_watermark_sha256,
    'normalizationSetSha256', v_detection_snapshot.normalization_set_sha256,
    'memberCount', v_member_count, 'memberSetSha256', v_member_set_sha256
  );
  v_snapshot_manifest_canonical := ops.canonical_jsonb_v1(v_snapshot_manifest);
  v_snapshot_sha256 := encode(extensions.digest(
    v_snapshot_manifest_canonical, 'sha256'
  ), 'hex');
  v_snapshot_terminal_payload := jsonb_build_object(
    'schemaVersion', 'dataset-snapshot-terminal-receipt.v1',
    'snapshotId', v_snapshot_id, 'state', 'READY',
    'aggregateVersion', 2, 'snapshotSha256', v_snapshot_sha256,
    'memberCount', v_member_count, 'memberSetSha256', v_member_set_sha256,
    'occurredAt', v_now
  );
  v_snapshot_terminal_canonical := ops.canonical_jsonb_v1(
    v_snapshot_terminal_payload
  );
  v_snapshot_terminal_digest := encode(extensions.digest(
    v_snapshot_terminal_canonical, 'sha256'
  ), 'hex');
  v_snapshot_terminal_audit_id := ops.append_audit_event(
    'snapshot:' || v_snapshot_id::text, 'SERVICE', 'workflow-worker',
    NULL::uuid, 'DATASET_SNAPSHOT_READY', 'DatasetSnapshot',
    v_snapshot_id::text, 'jobs.operate', 'SUCCESS', NULL, p_signal_id,
    v_snapshot_terminal_payload || jsonb_build_object(
      'terminalReceiptDigest', v_snapshot_terminal_digest
    )
  );
  PERFORM core.finalize_dataset_snapshot(
    v_snapshot_id, 1, 'READY', v_member_count, v_member_set_sha256,
    v_snapshot_manifest, v_snapshot_manifest_canonical,
    v_snapshot_terminal_digest, v_snapshot_terminal_audit_id,
    NULL, NULL
  );

  v_agent_run_id := gen_random_uuid();
  v_initial_transcript_sha256 := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion', 'agent-transcript.initial.v1',
      'runId', v_agent_run_id,
      'inputSnapshotSha256', v_snapshot_sha256,
      'promptSha256', v_policy.prompt_sha256,
      'outputSchemaSha256', v_policy.output_schema_sha256,
      'providerPolicySha256', v_policy.provider_policy_sha256
    )), 'sha256'
  ), 'hex');
  INSERT INTO ops.agent_runs(
    id, case_id, agent_type, objective, evidence_scope_ids,
    provider_policy, status, input_snapshot_hash, output_schema_version,
    max_cost, created_by, run_contract_version, dataset_snapshot_id,
    initial_transcript_sha256, control_state, prompt_id, prompt_version,
    prompt_sha256, output_schema_id, output_schema_contract_version,
    output_schema_sha256, provider_policy_version, provider_policy_sha256,
    provider_classification, provider_candidate_ids, max_micros_krw,
    reserved_micros_krw, settled_micros_krw, remaining_micros_krw,
    budget_reservation_state, budget_policy_version, budget_policy_sha256,
    max_provider_turns, max_tool_calls, completed_provider_turns,
    completed_tool_calls, next_turn_sequence, deadline_at,
    created_actor_type, created_service
  ) VALUES (
    v_agent_run_id, v_case_id, v_policy.agent_type,
    '신호 ' || p_signal_id::text || ' 조사', '[]'::jsonb,
    v_policy.provider_policy_version, 'QUEUED', v_snapshot_sha256,
    v_policy.output_schema_version,
    v_policy.max_run_micros_krw::numeric / 1000000,
    NULL, 2, v_snapshot_id, v_initial_transcript_sha256, 'NONE',
    v_policy.prompt_id, v_policy.prompt_version, v_policy.prompt_sha256,
    v_policy.output_schema_id, v_policy.output_schema_version,
    v_policy.output_schema_sha256, v_policy.provider_policy_version,
    v_policy.provider_policy_sha256, v_policy.provider_classification,
    v_policy.provider_candidate_ids, v_policy.max_run_micros_krw,
    v_policy.max_run_micros_krw, 0, v_policy.max_run_micros_krw,
    'RESERVED', v_policy.budget_policy_version,
    v_policy.budget_policy_sha256, v_policy.max_provider_turns,
    v_policy.max_tool_calls, 0, 0, 1,
    v_now + v_policy.deadline_interval, 'SERVICE', 'workflow-worker'
  );
  INSERT INTO ops.jobs(job_type, queue, payload, dedupe_key)
  VALUES (
    'AGENT_RUN', 'analysis-worker',
    jsonb_build_object('agentRunId', v_agent_run_id),
    'agent-run:' || v_agent_run_id::text
  ) RETURNING id INTO v_job_id;

  v_audit_id := ops.append_audit_event(
    'worker:signal-investigation:' || p_signal_id::text,
    'SERVICE', 'workflow-worker', NULL::uuid,
    'SIGNAL_INVESTIGATION_STARTED', 'Signal', p_signal_id::text,
    'jobs.operate', 'SUCCESS', NULL, p_signal_id,
    jsonb_build_object(
      'policyId', v_policy.policy_id, 'policyVersion', v_policy.version,
      'caseId', v_case_id, 'datasetSnapshotId', v_snapshot_id,
      'agentRunId', v_agent_run_id, 'jobId', v_job_id,
      'reservedMicrosKrw', v_policy.max_run_micros_krw
    )
  );
  v_payload := jsonb_build_object(
    'schemaVersion', 'signal-investigation-initiation-receipt.v1',
    'receiptId', v_receipt_id, 'signalId', p_signal_id,
    'ruleVersionId', v_signal.rule_version_id,
    'targetType', v_signal.target_type, 'targetId', v_signal.target_id,
    'producerJobId', p_producer_job_id,
    'policyId', v_policy.policy_id, 'policyVersion', v_policy.version,
    'disposition', 'STARTED', 'caseId', v_case_id,
    'datasetSnapshotId', v_snapshot_id, 'agentRunId', v_agent_run_id,
    'jobId', v_job_id,
    'reservedMicrosKrw', v_policy.max_run_micros_krw,
    'actorType', 'SERVICE', 'actorId', 'workflow-worker',
    'auditEventId', v_audit_id, 'occurredAt', v_now
  );
  v_canonical := ops.canonical_jsonb_v1(v_payload);
  v_digest := encode(extensions.digest(v_canonical, 'sha256'), 'hex');
  INSERT INTO ops.signal_investigation_initiation_receipts(
    receipt_id, signal_id, rule_version_id, target_type, target_id,
    producer_job_id, policy_id, policy_version, disposition, case_id,
    dataset_snapshot_id, agent_run_id, job_id, reserved_micros_krw,
    audit_event_id, receipt_payload, receipt_canonical, receipt_digest,
    created_at
  ) VALUES (
    v_receipt_id, p_signal_id, v_signal.rule_version_id,
    v_signal.target_type, v_signal.target_id, p_producer_job_id,
    v_policy.policy_id, v_policy.version, 'STARTED', v_case_id,
    v_snapshot_id, v_agent_run_id, v_job_id,
    v_policy.max_run_micros_krw, v_audit_id, v_payload, v_canonical,
    v_digest, v_now
  );
  RETURN QUERY SELECT 'STARTED'::text, v_case_id, v_snapshot_id,
    v_agent_run_id, v_job_id, v_receipt_id, 'SERVICE'::text,
    'workflow-worker'::text, false;
END
$$;
ALTER FUNCTION ops.process_signal_investigation_v1(uuid,uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.process_signal_investigation_v1(uuid,uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.process_signal_investigation_v1(uuid,uuid)
  TO gurine_workflow_worker;

-- The v2 receipt/actor authority is not decision-complete.  Preserve the
-- legacy claim, but reject v2 before any state or version mutation.
DROP FUNCTION ops.claim_agent_run_worker_v1(uuid);
CREATE FUNCTION ops.claim_agent_run_worker_v1(p_agent_run_id uuid)
RETURNS TABLE(
  case_id uuid,
  agent_type text,
  objective text,
  evidence_scope_ids jsonb,
  input_snapshot_hash char(64),
  max_cost numeric,
  version bigint,
  run_contract_version smallint,
  dataset_snapshot_id uuid
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM ops.agent_runs AS candidate
    WHERE candidate.id = p_agent_run_id
      AND candidate.run_contract_version = 2
  ) THEN
    RAISE EXCEPTION 'agent_run_v2_transition_authority_missing'
      USING ERRCODE = '55000';
  END IF;
  RETURN QUERY
  UPDATE ops.agent_runs AS run
  SET status = 'RUNNING',
      started_at = COALESCE(run.started_at, clock_timestamp()),
      updated_at = clock_timestamp(),
      version = CASE
        WHEN run.status = 'QUEUED' THEN run.version + 1
        ELSE run.version
      END
  WHERE run.id = p_agent_run_id
    AND run.run_contract_version = 1
    AND run.status IN ('QUEUED', 'RUNNING')
  RETURNING
    run.case_id, run.agent_type, run.objective, run.evidence_scope_ids,
    run.input_snapshot_hash, run.max_cost, run.version,
    run.run_contract_version, run.dataset_snapshot_id;
END
$$;
ALTER FUNCTION ops.claim_agent_run_worker_v1(uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.claim_agent_run_worker_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.claim_agent_run_worker_v1(uuid)
  TO gurine_analysis_worker;

-- The legacy transition cannot create the immutable AgentRunV2 control and
-- terminal receipt chain.  Keep its v1 behavior and reject v2 before any
-- output, version, or status mutation.
CREATE OR REPLACE FUNCTION ops.transition_agent_run_worker_v1(
  p_agent_run_id uuid,
  p_expected_version bigint,
  p_next_status text,
  p_provider text,
  p_model text,
  p_output_payload jsonb,
  p_output_schema_version text,
  p_actual_cost numeric,
  p_terminal boolean
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
DECLARE v_changed bigint;
BEGIN
  IF EXISTS (
    SELECT 1 FROM ops.agent_runs AS candidate
    WHERE candidate.id = p_agent_run_id
      AND candidate.run_contract_version = 2
  ) THEN
    RAISE EXCEPTION 'agent_run_v2_transition_authority_missing'
      USING ERRCODE = '55000';
  END IF;
  IF p_next_status IS NOT NULL AND p_next_status NOT IN
      ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED','BUDGET_BLOCKED','POLICY_BLOCKED') THEN
    RAISE EXCEPTION 'agent_run_status_invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE ops.agent_runs
     SET status = CASE WHEN p_terminal THEN COALESCE(p_next_status,status) ELSE status END,
         provider = COALESCE(p_provider,provider),
         model = COALESCE(p_model,model),
         output_payload = COALESCE(p_output_payload,output_payload),
         output_schema_version = COALESCE(p_output_schema_version,output_schema_version),
         actual_cost = COALESCE(p_actual_cost,actual_cost),
         completed_at = CASE WHEN p_terminal THEN COALESCE(completed_at,clock_timestamp()) ELSE completed_at END,
         updated_at = clock_timestamp(),
         version = version + 1
   WHERE id = p_agent_run_id
     AND run_contract_version = 1
     AND status = 'RUNNING'
     AND (p_expected_version IS NULL OR version = p_expected_version);
  GET DIAGNOSTICS v_changed = ROW_COUNT;
  RETURN v_changed = 1;
END
$$;
ALTER FUNCTION ops.transition_agent_run_worker_v1(
  uuid,bigint,text,text,text,jsonb,text,numeric,boolean
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_agent_run_worker_v1(
  uuid,bigint,text,text,text,jsonb,text,numeric,boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_agent_run_worker_v1(
  uuid,bigint,text,text,text,jsonb,text,numeric,boolean
) TO gurine_analysis_worker;

-- The active addendum does not define the immutable source-digest preimage
-- needed to create a new runnable DETECTION_DATASET build.  Keep the scheduler
-- boundary explicit and fail closed: no job is invented until that authority
-- is specified.
CREATE OR REPLACE FUNCTION ops.enqueue_due_detection_snapshot_builds_v1(
  p_limit bigint
)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'detection_snapshot_sweep_limit_invalid'
      USING ERRCODE = '22023';
  END IF;
  RETURN 0::bigint;
END
$$;
ALTER FUNCTION ops.enqueue_due_detection_snapshot_builds_v1(bigint)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.enqueue_due_detection_snapshot_builds_v1(bigint)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.enqueue_due_detection_snapshot_builds_v1(bigint)
  TO gurine_scheduler;

-- PostgreSQL checks function EXECUTE privileges for table CHECK expressions
-- under the DML caller even when a nullable digest branch is true.  Migration
-- 0032 grants these two roles direct DML on its relay ledgers, so close only
-- that pre-existing dependency while keeping PUBLIC and every other runtime
-- role denied.
GRANT EXECUTE ON FUNCTION ops.is_lower_sha256(text)
  TO gurine_analysis_worker, gurine_scheduler;
