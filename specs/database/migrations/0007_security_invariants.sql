BEGIN;


DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_notification_worker') THEN CREATE ROLE gurine_notification_worker NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_workflow_worker') THEN CREATE ROLE gurine_workflow_worker NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_document_extractor') THEN CREATE ROLE gurine_document_extractor NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_scheduler') THEN CREATE ROLE gurine_scheduler NOLOGIN; END IF;
END
$$;

GRANT USAGE ON SCHEMA extensions TO
  gurine_notification_worker, gurine_workflow_worker,
  gurine_document_extractor, gurine_scheduler;

GRANT USAGE ON SCHEMA ops, intake, editorial TO gurine_notification_worker;
GRANT SELECT ON intake.subscriptions, editorial.response_requests, editorial.responses, editorial.publication_revisions TO gurine_notification_worker;
GRANT SELECT, INSERT, UPDATE ON ops.email_deliveries, ops.jobs, ops.job_attempts, ops.inbox TO gurine_notification_worker;

GRANT USAGE ON SCHEMA ops, intake, editorial TO gurine_workflow_worker;
GRANT SELECT, INSERT, UPDATE ON ops.jobs, ops.job_attempts, ops.inbox, ops.outbox, intake.dataset_export_requests, intake.response_submissions, editorial.responses TO gurine_workflow_worker;

GRANT USAGE ON SCHEMA raw, core, ops TO gurine_document_extractor;
GRANT SELECT ON raw.source_documents TO gurine_document_extractor;
GRANT SELECT, INSERT, UPDATE ON core.parser_runs, ops.jobs, ops.job_attempts, ops.inbox TO gurine_document_extractor;
GRANT SELECT ON core.parser_versions TO gurine_document_extractor;

GRANT USAGE ON SCHEMA ops TO gurine_scheduler;
GRANT SELECT, INSERT, UPDATE ON ops.jobs, ops.queue_controls, ops.source_registry, ops.source_runs TO gurine_scheduler;

CREATE OR REPLACE FUNCTION ops.reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'immutable_record' USING ERRCODE='55000'; END $$;
CREATE TRIGGER audit_events_immutable BEFORE UPDATE OR DELETE ON ops.audit_events FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER review_snapshots_immutable BEFORE UPDATE OR DELETE ON editorial.review_snapshots FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER review_decisions_immutable BEFORE UPDATE OR DELETE ON editorial.review_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER publication_revisions_immutable BEFORE UPDATE OR DELETE ON editorial.publication_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER source_documents_immutable BEFORE UPDATE OR DELETE ON raw.source_documents FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER parsed_records_immutable BEFORE UPDATE OR DELETE ON raw.parsed_records FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER rule_runs_immutable BEFORE UPDATE OR DELETE ON core.rule_runs FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
ALTER TABLE intake.response_drafts ENABLE ROW LEVEL SECURITY; ALTER TABLE intake.response_attachments ENABLE ROW LEVEL SECURITY; ALTER TABLE intake.response_submissions ENABLE ROW LEVEL SECURITY; ALTER TABLE intake.correction_request_drafts ENABLE ROW LEVEL SECURITY; ALTER TABLE intake.dataset_export_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY response_drafts_token_scope ON intake.response_drafts USING(response_request_id::text=current_setting('gurine.response_request_id',true)) WITH CHECK(response_request_id::text=current_setting('gurine.response_request_id',true));
CREATE POLICY response_attachments_token_scope ON intake.response_attachments USING(response_request_id::text=current_setting('gurine.response_request_id',true)) WITH CHECK(response_request_id::text=current_setting('gurine.response_request_id',true));
CREATE POLICY response_submissions_token_scope ON intake.response_submissions USING(response_request_id::text=current_setting('gurine.response_request_id',true)) WITH CHECK(response_request_id::text=current_setting('gurine.response_request_id',true));
CREATE POLICY correction_drafts_token_scope ON intake.correction_request_drafts USING(token_hash=current_setting('gurine.token_hash',true)) WITH CHECK(token_hash=current_setting('gurine.token_hash',true));
CREATE POLICY dataset_exports_token_scope ON intake.dataset_export_requests USING(request_token_hash=current_setting('gurine.token_hash',true)) WITH CHECK(request_token_hash=current_setting('gurine.token_hash',true));
CREATE OR REPLACE FUNCTION ops.append_audit_event(p_actor_type text,p_actor_id text,p_session_id uuid,p_action text,p_object_type text,p_object_id text,p_capability text,p_outcome ops.audit_outcome,p_reason text,p_request_id uuid,p_details jsonb,p_event_hash char(64),p_previous_event_hash char(64)) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, ops, extensions, pg_temp AS $$ DECLARE v_id uuid; BEGIN INSERT INTO ops.audit_events(actor_type,actor_id,session_id,action,object_type,object_id,capability,outcome,reason,request_id,details,event_hash,previous_event_hash) VALUES(p_actor_type,p_actor_id,p_session_id,p_action,p_object_type,p_object_id,p_capability,p_outcome,p_reason,p_request_id,p_details,p_event_hash,p_previous_event_hash) RETURNING id INTO v_id; RETURN v_id; END $$;
CREATE OR REPLACE FUNCTION ops.enqueue_outbox(p_aggregate_type text,p_aggregate_id text,p_aggregate_version bigint,p_event_type text,p_payload jsonb,p_occurred_at timestamptz) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, ops, extensions, pg_temp AS $$ DECLARE v_id uuid; BEGIN INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES(p_aggregate_type,p_aggregate_id,p_aggregate_version,p_event_type,p_payload,p_occurred_at) RETURNING id INTO v_id; RETURN v_id; END $$;
REVOKE ALL ON FUNCTION ops.append_audit_event(text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb,char,char) FROM PUBLIC; REVOKE ALL ON FUNCTION ops.enqueue_outbox(text,text,bigint,text,jsonb,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.append_audit_event(text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb,char,char) TO gurine_control_api,gurine_submission_api,gurine_ingest_worker,gurine_analysis_worker,gurine_public_projector; GRANT EXECUTE ON FUNCTION ops.enqueue_outbox(text,text,bigint,text,jsonb,timestamptz) TO gurine_control_api,gurine_submission_api,gurine_ingest_worker,gurine_analysis_worker,gurine_public_projector;
REVOKE UPDATE,DELETE ON ops.audit_events,editorial.review_snapshots,editorial.review_decisions,editorial.publication_revisions,raw.source_documents,raw.parsed_records,core.rule_runs FROM gurine_control_api,gurine_submission_api,gurine_ingest_worker,gurine_analysis_worker,gurine_public_projector;
REVOKE ALL ON ALL TABLES IN SCHEMA intake FROM gurine_submission_api; GRANT SELECT,INSERT,UPDATE ON intake.response_drafts,intake.response_attachments,intake.response_submissions,intake.correction_request_drafts,intake.dataset_export_requests,intake.subscriptions,intake.correction_requests,intake.correction_attachments,intake.contact_requests TO gurine_submission_api; GRANT DELETE ON intake.response_attachments,intake.correction_request_drafts TO gurine_submission_api;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw REVOKE ALL ON TABLES FROM PUBLIC; ALTER DEFAULT PRIVILEGES IN SCHEMA core REVOKE ALL ON TABLES FROM PUBLIC; ALTER DEFAULT PRIVILEGES IN SCHEMA editorial REVOKE ALL ON TABLES FROM PUBLIC; ALTER DEFAULT PRIVILEGES IN SCHEMA intake REVOKE ALL ON TABLES FROM PUBLIC; ALTER DEFAULT PRIVILEGES IN SCHEMA ops REVOKE ALL ON TABLES FROM PUBLIC; ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC; ALTER DEFAULT PRIVILEGES IN SCHEMA ops REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
COMMIT;
