BEGIN;

CREATE TABLE ops.audit_exports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requested_by uuid NOT NULL REFERENCES ops.users(id),
  from_at timestamptz NOT NULL,
  to_at timestamptz NOT NULL,
  format text NOT NULL CHECK (format IN ('CSV','JSONL')),
  scope text NOT NULL CHECK (scope IN ('CASE','OBJECT','GLOBAL')),
  object_type text,
  object_id text,
  reason text NOT NULL CHECK (char_length(reason) BETWEEN 10 AND 2000),
  watermark_policy text NOT NULL CHECK (watermark_policy IN ('ACTOR_AND_TIME','CLASSIFICATION_BANNER')),
  status text NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','RUNNING','READY','FAILED','EXPIRED')),
  object_key text,
  content_sha256 char(64),
  row_count bigint CHECK (row_count IS NULL OR row_count >= 0),
  failure_code text,
  expires_at timestamptz NOT NULL,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  started_at timestamptz,
  completed_at timestamptz,
  CHECK (from_at < to_at),
  CHECK (to_at - from_at <= interval '31 days'),
  CHECK (expires_at > created_at),
  CHECK ((scope='GLOBAL' AND object_type IS NULL AND object_id IS NULL)
      OR (scope='CASE' AND object_type='CASE' AND object_id IS NOT NULL)
      OR (scope='OBJECT' AND object_type IN ('SIGNAL','SOURCE','USER','ROLE','JOB','PROVIDER') AND object_id IS NOT NULL)),
  CHECK ((status='READY') = (object_key IS NOT NULL AND content_sha256 IS NOT NULL AND completed_at IS NOT NULL))
);
CREATE INDEX audit_exports_requester_created_idx ON ops.audit_exports(requested_by, created_at DESC);
CREATE INDEX audit_exports_status_created_idx ON ops.audit_exports(status, created_at) WHERE status IN ('QUEUED','RUNNING');

INSERT INTO ops.capabilities(code,description,risk_level)
VALUES ('audit.export','범위·watermark·만료가 강제된 감사 기록 반출','CRITICAL')
ON CONFLICT (code) DO UPDATE SET description=EXCLUDED.description,risk_level=EXCLUDED.risk_level;
INSERT INTO ops.role_capabilities(role_id,capability_code)
SELECT r.id,'audit.export' FROM ops.roles r WHERE r.code IN ('AUDITOR','SECURITY_ADMIN','LEGAL_REVIEWER')
ON CONFLICT DO NOTHING;

GRANT SELECT,INSERT ON ops.audit_exports TO gurine_control_api;
GRANT SELECT,UPDATE ON ops.audit_exports TO gurine_workflow_worker;
GRANT SELECT ON ops.audit_exports TO gurine_auditor;
REVOKE INSERT,UPDATE,DELETE ON ops.audit_exports FROM gurine_public_api,gurine_submission_api,gurine_ingest_worker,gurine_analysis_worker,gurine_public_projector,gurine_notification_worker,gurine_document_extractor,gurine_scheduler,gurine_auditor,gurine_identity_api;

INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES ('audit.export_requested.v1','INTEGRATION',1,true,'payloads/audit_export_requested_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET category=EXCLUDED.category,schema_version=EXCLUDED.schema_version,active=EXCLUDED.active,payload_schema_uri=EXCLUDED.payload_schema_uri;

COMMIT;
