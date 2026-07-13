BEGIN;

CREATE TABLE ops.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  oidc_subject text NOT NULL UNIQUE,
  email extensions.citext NOT NULL UNIQUE,
  display_name text NOT NULL,
  status text NOT NULL CHECK (status IN ('INVITED','ACTIVE','DISABLED')),
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER users_updated_at BEFORE UPDATE ON ops.users FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE ops.roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  name text NOT NULL,
  description text NOT NULL,
  risk_level text NOT NULL CHECK (risk_level IN ('LOW','MEDIUM','HIGH','CRITICAL')),
  system_role boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE ops.capabilities (
  code text PRIMARY KEY,
  description text NOT NULL,
  risk_level text NOT NULL CHECK (risk_level IN ('LOW','MEDIUM','HIGH','CRITICAL'))
);

CREATE TABLE ops.role_capabilities (
  role_id uuid NOT NULL REFERENCES ops.roles(id) ON DELETE CASCADE,
  capability_code text NOT NULL REFERENCES ops.capabilities(code) ON DELETE CASCADE,
  PRIMARY KEY (role_id, capability_code)
);

CREATE TABLE ops.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE CASCADE,
  role_id uuid NOT NULL REFERENCES ops.roles(id) ON DELETE CASCADE,
  granted_by uuid NOT NULL REFERENCES ops.users(id),
  reason text NOT NULL,
  granted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid REFERENCES ops.users(id),
  UNIQUE (user_id, role_id, granted_at)
);
CREATE UNIQUE INDEX active_user_role_idx ON ops.user_roles (user_id, role_id)
WHERE revoked_at IS NULL;

CREATE TABLE ops.sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE CASCADE,
  session_token_hash char(64) NOT NULL UNIQUE,
  oidc_session_id text,
  auth_time timestamptz NOT NULL,
  step_up_at timestamptz,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  ip_hash char(64),
  user_agent_hash char(64),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE ops.idempotency_keys (
  scope text NOT NULL,
  key_hash char(64) NOT NULL,
  request_hash char(64) NOT NULL,
  response_status integer,
  response_body jsonb,
  resource_type text,
  resource_id text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (scope, key_hash)
);

CREATE TABLE ops.audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor_type text NOT NULL,
  actor_id text,
  session_id uuid,
  action text NOT NULL,
  object_type text,
  object_id text,
  capability text,
  outcome ops.audit_outcome NOT NULL,
  reason text,
  request_id uuid NOT NULL,
  ip_hash char(64),
  user_agent_hash char(64),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  previous_event_hash char(64),
  event_hash char(64) NOT NULL UNIQUE
);
CREATE INDEX audit_events_object_idx ON ops.audit_events (object_type, object_id, occurred_at DESC);
CREATE INDEX audit_events_actor_idx ON ops.audit_events (actor_id, occurred_at DESC);

CREATE TABLE ops.outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aggregate_type text NOT NULL,
  aggregate_id text NOT NULL,
  aggregate_version bigint NOT NULL,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  occurred_at timestamptz NOT NULL,
  available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  published_at timestamptz,
  attempt_count integer NOT NULL DEFAULT 0,
  last_error text,
  UNIQUE (aggregate_type, aggregate_id, aggregate_version, event_type)
);
CREATE INDEX outbox_unpublished_idx ON ops.outbox (available_at, id) WHERE published_at IS NULL;

CREATE TABLE ops.inbox (
  consumer text NOT NULL,
  event_id uuid NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  processed_at timestamptz,
  result text,
  PRIMARY KEY (consumer, event_id)
);

CREATE TABLE ops.jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_type text NOT NULL,
  queue text NOT NULL,
  status ops.job_status NOT NULL DEFAULT 'QUEUED',
  priority integer NOT NULL DEFAULT 100,
  payload jsonb NOT NULL,
  dedupe_key text,
  run_after timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_owner text,
  lease_token uuid,
  lease_expires_at timestamptz,
  fencing_token bigint NOT NULL DEFAULT 0,
  attempt_count integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 8,
  last_error_code text,
  last_error_detail text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz
);
CREATE UNIQUE INDEX jobs_dedupe_active_idx ON ops.jobs (job_type, dedupe_key)
WHERE dedupe_key IS NOT NULL AND status IN ('QUEUED','LEASED','RUNNING');
CREATE INDEX jobs_claim_idx ON ops.jobs (queue, status, run_after, priority, created_at);
CREATE TRIGGER jobs_updated_at BEFORE UPDATE ON ops.jobs FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE ops.job_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES ops.jobs(id) ON DELETE CASCADE,
  attempt integer NOT NULL,
  worker_id text NOT NULL,
  fencing_token bigint NOT NULL,
  started_at timestamptz NOT NULL,
  finished_at timestamptz,
  outcome text,
  error_code text,
  error_detail text,
  metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (job_id, attempt)
);

CREATE TABLE ops.source_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id text NOT NULL,
  mode text NOT NULL CHECK (mode IN ('INCREMENTAL','RECONCILE','FULL','BACKFILL','DRY_RUN')),
  checkpoint_before jsonb,
  checkpoint_after jsonb,
  status text NOT NULL CHECK (status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED','PAUSED','CANCELLED')),
  records_seen bigint NOT NULL DEFAULT 0,
  records_changed bigint NOT NULL DEFAULT 0,
  started_at timestamptz,
  completed_at timestamptz,
  report_object_key text,
  error_detail text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX source_runs_source_idx ON ops.source_runs (source_id, created_at DESC);

CREATE TABLE ops.source_incidents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id text NOT NULL,
  source_run_id uuid REFERENCES ops.source_runs(id),
  severity ops.incident_severity NOT NULL,
  incident_type text NOT NULL,
  summary text NOT NULL,
  impact jsonb NOT NULL,
  status text NOT NULL CHECK (status IN ('OPEN','ACKNOWLEDGED','MITIGATED','RESOLVED')),
  acknowledged_by uuid REFERENCES ops.users(id),
  acknowledged_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER source_incidents_updated_at BEFORE UPDATE ON ops.source_incidents FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE ops.provider_configs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_type text NOT NULL,
  name text NOT NULL,
  enabled boolean NOT NULL DEFAULT false,
  routing_policy jsonb NOT NULL,
  secret_reference text NOT NULL,
  data_retention_policy text NOT NULL,
  last_connection_test_at timestamptz,
  last_connection_test_status text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER provider_configs_updated_at BEFORE UPDATE ON ops.provider_configs FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE ops.cost_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid REFERENCES ops.provider_configs(id),
  case_id uuid,
  job_id uuid REFERENCES ops.jobs(id),
  occurred_at timestamptz NOT NULL,
  model text,
  input_units bigint,
  output_units bigint,
  amount numeric(18,6) NOT NULL CHECK (amount >= 0),
  currency char(3) NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX cost_events_time_idx ON ops.cost_events (occurred_at DESC);

CREATE TABLE ops.budget_limits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope text NOT NULL UNIQUE,
  daily_limit numeric(18,6) NOT NULL,
  monthly_limit numeric(18,6) NOT NULL,
  currency char(3) NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  updated_by uuid NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE ops.kill_switches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  scope jsonb NOT NULL,
  state ops.kill_switch_state NOT NULL DEFAULT 'INACTIVE',
  reason text,
  activated_by uuid,
  activated_at timestamptz,
  expires_at timestamptz,
  deactivated_by uuid,
  deactivated_at timestamptz,
  version bigint NOT NULL DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE ops.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE CASCADE,
  notification_type text NOT NULL,
  title text NOT NULL,
  body text NOT NULL,
  object_type text,
  object_id text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  read_at timestamptz
);
CREATE INDEX notifications_unread_idx ON ops.notifications (user_id, created_at DESC) WHERE read_at IS NULL;

CREATE TABLE public.cases (
  id uuid PRIMARY KEY,
  slug text NOT NULL UNIQUE,
  title text NOT NULL,
  public_state text NOT NULL,
  latest_revision integer NOT NULL,
  summary text NOT NULL,
  published_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  source_freshness jsonb NOT NULL,
  search_document tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('simple', coalesce(title,'')), 'A') ||
    setweight(to_tsvector('simple', coalesce(summary,'')), 'B')
  ) STORED
);
CREATE INDEX public_cases_search_idx ON public.cases USING gin (search_document);
CREATE INDEX public_cases_state_time_idx ON public.cases (public_state, updated_at DESC);

CREATE TABLE public.case_revisions (
  case_id uuid NOT NULL REFERENCES public.cases(id) ON DELETE CASCADE,
  revision integer NOT NULL,
  state editorial.publication_state NOT NULL,
  payload jsonb NOT NULL,
  payload_sha256 char(64) NOT NULL,
  published_at timestamptz NOT NULL,
  supersedes_revision integer,
  PRIMARY KEY (case_id, revision)
);

CREATE TABLE public.agencies (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  agency_type text NOT NULL,
  jurisdiction text,
  coverage jsonb NOT NULL,
  descriptive_metrics jsonb NOT NULL,
  case_counts jsonb NOT NULL,
  updated_at timestamptz NOT NULL,
  search_document tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(name,''))) STORED
);
CREATE INDEX public_agencies_search_idx ON public.agencies USING gin (search_document);

CREATE TABLE public.suppliers (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  business_status text,
  coverage jsonb NOT NULL,
  descriptive_metrics jsonb NOT NULL,
  case_counts jsonb NOT NULL,
  identity_warnings jsonb NOT NULL,
  updated_at timestamptz NOT NULL,
  search_document tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(name,''))) STORED
);
CREATE INDEX public_suppliers_search_idx ON public.suppliers USING gin (search_document);

CREATE TABLE public.contracts (
  id uuid PRIMARY KEY,
  contract_number text,
  title text NOT NULL,
  agency_id uuid REFERENCES public.agencies(id),
  supplier_id uuid REFERENCES public.suppliers(id),
  status text NOT NULL,
  signed_at date,
  amount jsonb,
  detail jsonb NOT NULL,
  updated_at timestamptz NOT NULL,
  search_document tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('simple', coalesce(title,'')), 'A') ||
    setweight(to_tsvector('simple', coalesce(contract_number,'')), 'B')
  ) STORED
);
CREATE INDEX public_contracts_search_idx ON public.contracts USING gin (search_document);

CREATE TABLE public.corrections (
  id uuid PRIMARY KEY,
  case_id uuid NOT NULL REFERENCES public.cases(id),
  source_revision integer NOT NULL,
  target_revision integer,
  summary text NOT NULL,
  reason text NOT NULL,
  published_at timestamptz NOT NULL
);

CREATE TABLE public.source_status (
  source_id text PRIMARY KEY,
  display_name text NOT NULL,
  status text NOT NULL,
  last_success_at timestamptz,
  expected_frequency interval,
  lag_seconds bigint,
  affected_scope jsonb NOT NULL,
  public_message text,
  updated_at timestamptz NOT NULL
);

CREATE TABLE public.rules (
  rule_id text PRIMARY KEY,
  name text NOT NULL,
  active_version text NOT NULL,
  public_description text NOT NULL,
  requirements jsonb NOT NULL,
  exclusions jsonb NOT NULL,
  limitations jsonb NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE public.datasets (
  id text PRIMARY KEY,
  title text NOT NULL,
  description text NOT NULL,
  format text NOT NULL,
  coverage jsonb NOT NULL,
  license text NOT NULL,
  download_url text,
  updated_at timestamptz NOT NULL
);

CREATE TABLE public.transparency_reports (
  id uuid PRIMARY KEY,
  period_start date NOT NULL,
  period_end date NOT NULL,
  title text NOT NULL,
  summary text NOT NULL,
  report jsonb NOT NULL,
  published_at timestamptz NOT NULL
);

COMMIT;
