BEGIN;

CREATE TABLE editorial.cases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_slug text UNIQUE,
  title text NOT NULL,
  investigation_state editorial.investigation_state NOT NULL DEFAULT 'SIGNAL_DETECTED',
  publication_state editorial.publication_state NOT NULL DEFAULT 'NEVER_PUBLISHED',
  resolution_code editorial.resolution_code NOT NULL DEFAULT 'NONE',
  summary text,
  priority text NOT NULL DEFAULT 'NORMAL',
  lead_investigator_id uuid,
  editor_id uuid,
  legal_review_required boolean NOT NULL DEFAULT false,
  current_review_snapshot_id uuid,
  current_publication_revision integer,
  version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX cases_state_priority_idx ON editorial.cases (investigation_state, publication_state, priority, updated_at DESC);
CREATE TRIGGER cases_updated_at BEFORE UPDATE ON editorial.cases FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE editorial.case_signals (
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE CASCADE,
  signal_id uuid NOT NULL REFERENCES core.anomaly_signals(id),
  link_reason text NOT NULL,
  linked_by uuid NOT NULL,
  linked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (case_id, signal_id)
);

CREATE TABLE editorial.hypotheses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE CASCADE,
  statement text NOT NULL,
  status text NOT NULL CHECK (status IN ('OPEN','SUPPORTED','CONTRADICTED','RESOLVED')),
  unknowns jsonb NOT NULL DEFAULT '[]'::jsonb,
  version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER hypotheses_updated_at BEFORE UPDATE ON editorial.hypotheses FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE editorial.evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE CASCADE,
  evidence_type text NOT NULL,
  title text NOT NULL,
  description text,
  source_document_id uuid REFERENCES raw.source_documents(id),
  source_url text,
  source_locator text NOT NULL,
  content_sha256 char(64) NOT NULL,
  classification editorial.evidence_classification NOT NULL DEFAULT 'PUBLIC',
  verification_status text NOT NULL CHECK (verification_status IN ('PENDING','VERIFIED','REJECTED','NEEDS_WORK')),
  verified_by uuid,
  verified_at timestamptz,
  redacted_public_excerpt text,
  version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX evidence_case_idx ON editorial.evidence (case_id, verification_status);
CREATE TRIGGER evidence_updated_at BEFORE UPDATE ON editorial.evidence FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE editorial.hypothesis_evidence (
  hypothesis_id uuid NOT NULL REFERENCES editorial.hypotheses(id) ON DELETE CASCADE,
  evidence_id uuid NOT NULL REFERENCES editorial.evidence(id) ON DELETE CASCADE,
  relation text NOT NULL CHECK (relation IN ('SUPPORTS','CONTRADICTS','CONTEXT')),
  added_by uuid NOT NULL,
  added_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (hypothesis_id, evidence_id, relation)
);

CREATE TABLE editorial.claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE CASCADE,
  claim_type editorial.claim_type NOT NULL,
  text text NOT NULL,
  limitations jsonb NOT NULL DEFAULT '[]'::jsonb,
  validation_status text NOT NULL DEFAULT 'DRAFT',
  version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX claims_case_idx ON editorial.claims (case_id, created_at);
CREATE TRIGGER claims_updated_at BEFORE UPDATE ON editorial.claims FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE editorial.claim_evidence (
  claim_id uuid NOT NULL REFERENCES editorial.claims(id) ON DELETE CASCADE,
  evidence_id uuid NOT NULL REFERENCES editorial.evidence(id),
  citation_label text NOT NULL,
  citation_order integer NOT NULL CHECK (citation_order > 0),
  supports text NOT NULL CHECK (supports IN ('FACT','CALCULATION','LIMITATION','CONTEXT')),
  PRIMARY KEY (claim_id, evidence_id)
);

CREATE TABLE editorial.response_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE CASCADE,
  party_type text NOT NULL CHECK (party_type IN ('AGENCY','SUPPLIER','OTHER')),
  party_entity_id uuid,
  party_name text NOT NULL,
  recipient_email_hash char(64) NOT NULL,
  recipient_email_encrypted bytea NOT NULL,
  questions jsonb NOT NULL,
  requested_publication_scope jsonb NOT NULL,
  due_at timestamptz NOT NULL,
  sent_at timestamptz,
  status text NOT NULL CHECK (status IN ('DRAFT','SENT','VIEWED','SUBMITTED','CLOSED','EXPIRED')),
  version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX response_requests_case_idx ON editorial.response_requests (case_id, status);
CREATE TRIGGER response_requests_updated_at BEFORE UPDATE ON editorial.response_requests FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE editorial.responses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE CASCADE,
  response_request_id uuid REFERENCES editorial.response_requests(id),
  submission_id uuid,
  party_name text NOT NULL,
  submitted_at timestamptz NOT NULL,
  verified_at timestamptz,
  verified_by uuid,
  full_text_encrypted bytea NOT NULL,
  public_excerpt text,
  publication_consent jsonb NOT NULL,
  editorial_status text NOT NULL CHECK (editorial_status IN ('PENDING','ACCEPTED','PARTIAL','REJECTED','PUBLISHED')),
  version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER responses_updated_at BEFORE UPDATE ON editorial.responses FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE editorial.claim_responses (
  claim_id uuid NOT NULL REFERENCES editorial.claims(id) ON DELETE CASCADE,
  response_id uuid NOT NULL REFERENCES editorial.responses(id),
  relation text NOT NULL CHECK (relation IN ('RESPONDS','DISPUTES','EXPLAINS','NO_COMMENT')),
  PRIMARY KEY (claim_id, response_id)
);

CREATE TABLE editorial.review_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id),
  case_version bigint NOT NULL,
  snapshot_sha256 char(64) NOT NULL UNIQUE,
  snapshot_payload jsonb NOT NULL,
  automated_gate_results jsonb NOT NULL,
  unresolved_blockers jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

ALTER TABLE editorial.cases
  ADD CONSTRAINT cases_current_snapshot_fk
  FOREIGN KEY (current_review_snapshot_id) REFERENCES editorial.review_snapshots(id);

CREATE TABLE editorial.review_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_snapshot_id uuid NOT NULL REFERENCES editorial.review_snapshots(id),
  reviewer_id uuid NOT NULL,
  decision editorial.review_decision NOT NULL,
  reason text NOT NULL,
  criteria jsonb NOT NULL,
  reviewer_independence jsonb NOT NULL,
  reauth_context_hash char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (review_snapshot_id, reviewer_id)
);

CREATE TABLE editorial.publication_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id),
  revision integer NOT NULL CHECK (revision > 0),
  state editorial.publication_state NOT NULL,
  review_snapshot_id uuid NOT NULL REFERENCES editorial.review_snapshots(id),
  public_payload jsonb NOT NULL,
  public_payload_sha256 char(64) NOT NULL,
  preview_sha256 char(64) NOT NULL,
  published_by uuid NOT NULL,
  published_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  supersedes_revision integer,
  reason text,
  UNIQUE (case_id, revision),
  UNIQUE (case_id, public_payload_sha256)
);

CREATE TABLE editorial.corrections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id),
  source_revision integer NOT NULL,
  target_revision integer,
  summary text NOT NULL,
  reason text NOT NULL,
  affected_claim_ids jsonb NOT NULL,
  status text NOT NULL CHECK (status IN ('DRAFT','REVIEW','PUBLISHED','REJECTED')),
  assigned_user_id uuid,
  version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER corrections_updated_at BEFORE UPDATE ON editorial.corrections FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE editorial.assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  object_type text NOT NULL,
  object_id uuid NOT NULL,
  assignee_user_id uuid NOT NULL,
  assigned_by uuid NOT NULL,
  reason text,
  active boolean NOT NULL DEFAULT true,
  assigned_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  ended_at timestamptz
);
CREATE UNIQUE INDEX active_assignment_idx ON editorial.assignments (object_type, object_id)
WHERE active;

CREATE TABLE intake.response_access_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  response_request_id uuid NOT NULL REFERENCES editorial.response_requests(id),
  token_hash char(64) NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  max_uses integer NOT NULL DEFAULT 20 CHECK (max_uses > 0),
  use_count integer NOT NULL DEFAULT 0 CHECK (use_count >= 0),
  revoked_at timestamptz,
  last_used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE intake.response_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  response_request_id uuid NOT NULL REFERENCES editorial.response_requests(id),
  version bigint NOT NULL DEFAULT 1,
  answers_encrypted bytea NOT NULL,
  publication_consent jsonb NOT NULL,
  saved_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL,
  UNIQUE (response_request_id)
);

CREATE TABLE intake.response_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  response_request_id uuid NOT NULL REFERENCES editorial.response_requests(id),
  draft_id uuid REFERENCES intake.response_drafts(id),
  original_filename_encrypted bytea NOT NULL,
  media_type text NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes BETWEEN 1 AND 52428800),
  sha256 char(64) NOT NULL,
  object_key text NOT NULL,
  upload_status text NOT NULL CHECK (upload_status IN ('PENDING','UPLOADED','FINALIZED','FAILED','DELETED')),
  scan_status text NOT NULL CHECK (scan_status IN ('PENDING','CLEAN','INFECTED','FAILED')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (response_request_id, sha256)
);

CREATE TABLE intake.response_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  response_request_id uuid NOT NULL REFERENCES editorial.response_requests(id),
  draft_version bigint NOT NULL,
  submission_sha256 char(64) NOT NULL UNIQUE,
  answers_encrypted bytea NOT NULL,
  publication_consent jsonb NOT NULL,
  status intake.submission_status NOT NULL DEFAULT 'SUBMITTED',
  submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  receipt_token_hash char(64) NOT NULL UNIQUE,
  editorial_response_id uuid REFERENCES editorial.responses(id),
  CONSTRAINT response_submissions_one_per_request UNIQUE (response_request_id)
);

CREATE TABLE intake.correction_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_case_slug text,
  publication_revision integer,
  requester_type text NOT NULL,
  contact_email_hash char(64) NOT NULL,
  contact_email_encrypted bytea NOT NULL,
  summary text NOT NULL,
  requested_changes jsonb NOT NULL,
  evidence_description text,
  status intake.submission_status NOT NULL DEFAULT 'SUBMITTED',
  receipt_token_hash char(64) NOT NULL UNIQUE,
  assigned_user_id uuid,
  submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX correction_requests_status_idx ON intake.correction_requests (status, submitted_at);
CREATE TRIGGER correction_requests_updated_at BEFORE UPDATE ON intake.correction_requests FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE intake.correction_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  correction_request_id uuid NOT NULL REFERENCES intake.correction_requests(id) ON DELETE CASCADE,
  original_filename_encrypted bytea NOT NULL,
  media_type text NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes BETWEEN 1 AND 52428800),
  sha256 char(64) NOT NULL,
  object_key text NOT NULL,
  scan_status text NOT NULL CHECK (scan_status IN ('PENDING','CLEAN','INFECTED','FAILED')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE intake.contact_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category text NOT NULL,
  name_encrypted bytea NOT NULL,
  email_hash char(64) NOT NULL,
  email_encrypted bytea NOT NULL,
  subject text NOT NULL,
  message_encrypted bytea NOT NULL,
  status text NOT NULL DEFAULT 'RECEIVED',
  receipt_token_hash char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE intake.subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email_hash char(64) NOT NULL,
  email_encrypted bytea NOT NULL,
  topics jsonb NOT NULL,
  frequency text NOT NULL CHECK (frequency IN ('IMMEDIATE','DAILY','WEEKLY')),
  locale text NOT NULL DEFAULT 'ko-KR',
  status text NOT NULL CHECK (status IN ('PENDING','ACTIVE','PAUSED','UNSUBSCRIBED')),
  verification_token_hash char(64),
  management_token_hash char(64) NOT NULL UNIQUE,
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (email_hash, topics)
);
CREATE TRIGGER subscriptions_updated_at BEFORE UPDATE ON intake.subscriptions FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

COMMIT;
