BEGIN;

-- Reset every runtime privilege role to a closed, table-specific grant set.
REVOKE ALL ON ALL TABLES IN SCHEMA raw, core, editorial, intake, ops, public FROM
  gurine_public_api, gurine_submission_api, gurine_control_api,
  gurine_ingest_worker, gurine_analysis_worker, gurine_public_projector,
  gurine_notification_worker, gurine_workflow_worker,
  gurine_document_extractor, gurine_scheduler, gurine_auditor;

GRANT USAGE ON SCHEMA public TO gurine_public_api;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO gurine_public_api;

GRANT USAGE ON SCHEMA raw, core, editorial, intake, ops TO gurine_control_api;
GRANT SELECT ON raw.source_documents TO gurine_control_api;
GRANT SELECT ON ALL TABLES IN SCHEMA core, editorial, intake, ops TO gurine_control_api;
GRANT INSERT, UPDATE ON
  editorial.cases, editorial.case_signals, editorial.hypotheses,
  editorial.evidence, editorial.hypothesis_evidence, editorial.claims,
  editorial.claim_evidence, editorial.response_requests, editorial.responses,
  editorial.claim_responses, editorial.corrections, editorial.assignments,
  editorial.review_assignments, editorial.retraction_drafts,
  editorial.publication_access_decisions, editorial.evidence_redactions,
  editorial.publication_previews, editorial.evidence_links,
  editorial.legal_holds
TO gurine_control_api;
GRANT DELETE ON
  editorial.case_signals, editorial.hypothesis_evidence,
  editorial.claim_evidence, editorial.claim_responses,
  editorial.evidence_links
TO gurine_control_api;
GRANT INSERT ON
  editorial.review_snapshots, editorial.review_decisions,
  editorial.publication_revisions
TO gurine_control_api;
GRANT INSERT, UPDATE ON
  core.rule_versions, core.rule_evaluations, core.anomaly_signals
TO gurine_control_api;
GRANT INSERT, UPDATE ON
  ops.users, ops.user_roles, ops.sessions, ops.idempotency_keys,
  ops.jobs, ops.job_attempts, ops.source_runs, ops.source_incidents,
  ops.source_registry, ops.source_checkpoints, ops.schema_drifts,
  ops.schema_mappings, ops.provider_configs, ops.provider_connection_tests,
  ops.cost_events, ops.budget_limits, ops.kill_switches, ops.notifications,
  ops.tasks, ops.saved_views, ops.agent_runs, ops.agent_suggestions,
  ops.access_requests, ops.access_reviews, ops.role_change_proposals,
  ops.retention_requests, ops.queue_controls, ops.audit_verification_runs,
  ops.job_query_snapshots
TO gurine_control_api;
GRANT DELETE ON ops.saved_views, ops.notifications TO gurine_control_api;

GRANT USAGE ON SCHEMA intake, editorial, ops TO gurine_submission_api;
GRANT SELECT, INSERT, UPDATE ON ops.idempotency_keys TO gurine_submission_api;
GRANT SELECT ON intake.response_access_tokens TO gurine_submission_api;

GRANT USAGE ON SCHEMA raw, core, ops TO gurine_ingest_worker;
GRANT SELECT, INSERT, UPDATE ON
  raw.source_fetches, raw.source_documents, raw.parsed_records
TO gurine_ingest_worker;
GRANT SELECT, INSERT, UPDATE ON
  core.agencies, core.agency_identifiers, core.suppliers,
  core.supplier_identifiers, core.entity_aliases, core.contracts,
  core.contract_line_items, core.contract_changes, core.field_provenance,
  core.price_observations
TO gurine_ingest_worker;
GRANT SELECT, INSERT, UPDATE ON
  ops.source_registry, ops.source_checkpoints, ops.source_runs,
  ops.source_incidents, ops.schema_drifts, ops.schema_mappings,
  ops.jobs, ops.job_attempts, ops.inbox
TO gurine_ingest_worker;

GRANT USAGE ON SCHEMA raw, core, editorial, ops TO gurine_analysis_worker;
GRANT SELECT ON ALL TABLES IN SCHEMA raw, core, editorial TO gurine_analysis_worker;
GRANT INSERT, UPDATE ON
  core.rule_versions, core.rule_evaluations, core.rule_runs,
  core.anomaly_signals
TO gurine_analysis_worker;
GRANT INSERT, UPDATE ON
  ops.agent_runs, ops.agent_suggestions, ops.cost_events,
  ops.jobs, ops.job_attempts, ops.inbox
TO gurine_analysis_worker;

GRANT USAGE ON SCHEMA core, editorial, ops, public TO gurine_public_projector;
GRANT SELECT ON
  core.agencies, core.suppliers, core.contracts, core.contract_line_items,
  core.contract_changes, core.rule_versions, core.anomaly_signals,
  editorial.cases, editorial.claims, editorial.claim_evidence,
  editorial.evidence, editorial.responses, editorial.review_snapshots,
  editorial.review_decisions, editorial.publication_revisions,
  editorial.corrections, editorial.publication_access_decisions,
  ops.event_types, ops.outbox, ops.inbox
TO gurine_public_projector;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO gurine_public_projector;
GRANT INSERT, UPDATE ON ops.inbox TO gurine_public_projector;

GRANT USAGE ON SCHEMA intake, editorial, ops TO gurine_notification_worker;
GRANT SELECT ON
  intake.subscriptions, editorial.response_requests, editorial.responses,
  editorial.publication_revisions, ops.provider_configs
TO gurine_notification_worker;
GRANT SELECT, INSERT, UPDATE ON
  ops.email_deliveries, ops.jobs, ops.job_attempts, ops.inbox
TO gurine_notification_worker;

GRANT USAGE ON SCHEMA core, editorial, intake, ops, public TO gurine_workflow_worker;
GRANT SELECT ON
  intake.response_attachments, intake.response_submissions,
  intake.correction_requests, intake.correction_attachments,
  intake.dataset_export_requests,
  editorial.response_requests, editorial.responses, editorial.corrections,
  ops.jobs, ops.job_attempts, ops.inbox, ops.outbox, ops.event_types, ops.tasks
TO gurine_workflow_worker;
GRANT INSERT, UPDATE ON
  ops.jobs, ops.job_attempts, ops.inbox, editorial.responses, ops.tasks
TO gurine_workflow_worker;

GRANT USAGE ON SCHEMA raw, core, ops TO gurine_document_extractor;
GRANT SELECT ON raw.source_documents, core.parser_versions TO gurine_document_extractor;
GRANT SELECT, INSERT, UPDATE ON
  core.parser_runs, ops.jobs, ops.job_attempts, ops.inbox
TO gurine_document_extractor;

GRANT USAGE ON SCHEMA core, ops TO gurine_scheduler;
GRANT SELECT ON core.rule_versions TO gurine_scheduler;
GRANT SELECT, INSERT, UPDATE ON
  ops.jobs, ops.queue_controls, ops.source_registry, ops.source_runs
TO gurine_scheduler;

GRANT USAGE ON SCHEMA ops TO gurine_auditor;
GRANT SELECT ON
  ops.audit_events, ops.audit_chain_heads, ops.audit_verification_runs
TO gurine_auditor;

-- No runtime role may bypass the append-only audit/outbox boundaries.
REVOKE INSERT, UPDATE, DELETE ON ops.audit_events, ops.audit_chain_heads, ops.outbox FROM
  gurine_public_api, gurine_submission_api, gurine_control_api,
  gurine_ingest_worker, gurine_analysis_worker, gurine_public_projector,
  gurine_notification_worker, gurine_workflow_worker,
  gurine_document_extractor, gurine_scheduler, gurine_auditor;

-- Immutable publication/review records are insert-only for the control boundary.
REVOKE UPDATE, DELETE ON
  editorial.review_snapshots, editorial.review_decisions,
  editorial.publication_revisions, raw.parsed_records
FROM
  gurine_submission_api, gurine_control_api, gurine_ingest_worker,
  gurine_analysis_worker, gurine_public_projector,
  gurine_notification_worker, gurine_workflow_worker,
  gurine_document_extractor, gurine_scheduler;

ALTER DEFAULT PRIVILEGES IN SCHEMA raw REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA core REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA editorial REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA intake REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA ops REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

COMMIT;
