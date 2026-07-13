BEGIN;

CREATE TABLE raw.source_fetches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id text NOT NULL,
  source_run_id uuid,
  external_locator text NOT NULL,
  requested_at timestamptz NOT NULL,
  completed_at timestamptz,
  http_status integer,
  content_type text,
  etag text,
  last_modified text,
  payload_sha256 char(64),
  payload_size_bytes bigint CHECK (payload_size_bytes IS NULL OR payload_size_bytes >= 0),
  object_key text,
  error_code text,
  error_detail text,
  attempt integer NOT NULL DEFAULT 1 CHECK (attempt > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (source_id, external_locator, payload_sha256)
);

CREATE INDEX source_fetches_source_time_idx ON raw.source_fetches (source_id, requested_at DESC);
CREATE INDEX source_fetches_run_idx ON raw.source_fetches (source_run_id);

CREATE TABLE raw.source_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id text NOT NULL,
  source_fetch_id uuid REFERENCES raw.source_fetches(id),
  external_id text NOT NULL,
  external_version text,
  canonical_url text,
  retrieved_at timestamptz NOT NULL,
  source_published_at timestamptz,
  content_type text NOT NULL,
  content_sha256 char(64) NOT NULL,
  content_size_bytes bigint NOT NULL CHECK (content_size_bytes >= 0),
  object_key text NOT NULL,
  status core.source_document_status NOT NULL DEFAULT 'FETCHED',
  parser_name text,
  parser_version text,
  schema_version text,
  prompt_injection_flags jsonb NOT NULL DEFAULT '[]'::jsonb,
  quarantine_reason text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (source_id, external_id, content_sha256)
);

CREATE INDEX source_documents_source_external_idx ON raw.source_documents (source_id, external_id);
CREATE INDEX source_documents_status_idx ON raw.source_documents (status, retrieved_at);
CREATE TRIGGER source_documents_updated_at BEFORE UPDATE ON raw.source_documents
FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE raw.parsed_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_document_id uuid NOT NULL REFERENCES raw.source_documents(id),
  record_type text NOT NULL,
  record_index integer NOT NULL CHECK (record_index >= 0),
  parser_version text NOT NULL,
  payload jsonb NOT NULL,
  payload_sha256 char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (source_document_id, record_type, record_index, parser_version)
);

CREATE TABLE core.agencies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_name text NOT NULL,
  agency_type text NOT NULL,
  jurisdiction text,
  parent_agency_id uuid REFERENCES core.agencies(id),
  active boolean NOT NULL DEFAULT true,
  identity_confidence numeric(5,4) CHECK (identity_confidence BETWEEN 0 AND 1),
  identity_status text NOT NULL DEFAULT 'VERIFIED',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX agencies_name_trgm_idx ON core.agencies USING gin (canonical_name extensions.gin_trgm_ops);
CREATE TRIGGER agencies_updated_at BEFORE UPDATE ON core.agencies FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE core.agency_identifiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES core.agencies(id) ON DELETE CASCADE,
  scheme text NOT NULL,
  value text NOT NULL,
  source_document_id uuid REFERENCES raw.source_documents(id),
  valid_from date,
  valid_to date,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (scheme, value)
);

CREATE TABLE core.suppliers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_name text NOT NULL,
  business_status text,
  incorporation_date date,
  identity_confidence numeric(5,4) CHECK (identity_confidence BETWEEN 0 AND 1),
  identity_status text NOT NULL DEFAULT 'UNVERIFIED',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX suppliers_name_trgm_idx ON core.suppliers USING gin (canonical_name extensions.gin_trgm_ops);
CREATE TRIGGER suppliers_updated_at BEFORE UPDATE ON core.suppliers FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE core.supplier_identifiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_id uuid NOT NULL REFERENCES core.suppliers(id) ON DELETE CASCADE,
  scheme text NOT NULL,
  value_hash char(64) NOT NULL,
  display_value text,
  source_document_id uuid REFERENCES raw.source_documents(id),
  verification_status text NOT NULL DEFAULT 'UNVERIFIED',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (scheme, value_hash)
);

CREATE TABLE core.entity_aliases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type text NOT NULL CHECK (entity_type IN ('AGENCY','SUPPLIER')),
  entity_id uuid NOT NULL,
  alias text NOT NULL,
  normalized_alias text NOT NULL,
  source_document_id uuid REFERENCES raw.source_documents(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (entity_type, entity_id, normalized_alias)
);
CREATE INDEX entity_aliases_normalized_trgm_idx ON core.entity_aliases USING gin (normalized_alias extensions.gin_trgm_ops);

CREATE TABLE core.contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id text NOT NULL,
  external_contract_id text NOT NULL,
  contract_number text,
  title text NOT NULL,
  agency_id uuid NOT NULL REFERENCES core.agencies(id),
  supplier_id uuid REFERENCES core.suppliers(id),
  status core.contract_status NOT NULL DEFAULT 'UNKNOWN',
  procurement_method text,
  signed_at date,
  start_at date,
  end_at date,
  currency char(3) NOT NULL DEFAULT 'KRW',
  original_amount numeric(24,4) CHECK (original_amount IS NULL OR original_amount >= 0),
  current_amount numeric(24,4) CHECK (current_amount IS NULL OR current_amount >= 0),
  vat_basis text,
  bundle_status text NOT NULL DEFAULT 'UNKNOWN',
  normalization_version text NOT NULL,
  source_document_id uuid NOT NULL REFERENCES raw.source_documents(id),
  source_record_locator text NOT NULL,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (source_id, external_contract_id)
);
CREATE INDEX contracts_agency_date_idx ON core.contracts (agency_id, signed_at DESC);
CREATE INDEX contracts_supplier_date_idx ON core.contracts (supplier_id, signed_at DESC);
CREATE INDEX contracts_title_trgm_idx ON core.contracts USING gin (title extensions.gin_trgm_ops);
CREATE TRIGGER contracts_updated_at BEFORE UPDATE ON core.contracts FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE core.contract_line_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES core.contracts(id) ON DELETE CASCADE,
  line_number integer NOT NULL CHECK (line_number > 0),
  raw_description text NOT NULL,
  normalized_category text,
  manufacturer text,
  model text,
  specification jsonb NOT NULL DEFAULT '{}'::jsonb,
  quantity numeric(24,6) CHECK (quantity IS NULL OR quantity >= 0),
  unit text,
  unit_price numeric(24,4) CHECK (unit_price IS NULL OR unit_price >= 0),
  total_price numeric(24,4) CHECK (total_price IS NULL OR total_price >= 0),
  vat_included boolean,
  shipping_included boolean,
  installation_included boolean,
  training_included boolean,
  maintenance_included boolean,
  warranty_months integer CHECK (warranty_months IS NULL OR warranty_months >= 0),
  certification_requirements jsonb NOT NULL DEFAULT '[]'::jsonb,
  bundle_components jsonb NOT NULL DEFAULT '[]'::jsonb,
  comparison_eligibility text NOT NULL DEFAULT 'UNKNOWN',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (contract_id, line_number)
);
CREATE INDEX line_items_category_idx ON core.contract_line_items (normalized_category);
CREATE INDEX line_items_description_trgm_idx ON core.contract_line_items USING gin (raw_description extensions.gin_trgm_ops);
CREATE TRIGGER line_items_updated_at BEFORE UPDATE ON core.contract_line_items FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE core.contract_changes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES core.contracts(id) ON DELETE CASCADE,
  external_change_id text,
  change_sequence integer NOT NULL CHECK (change_sequence > 0),
  changed_at date,
  previous_amount numeric(24,4),
  new_amount numeric(24,4),
  previous_end_at date,
  new_end_at date,
  reason text,
  source_document_id uuid NOT NULL REFERENCES raw.source_documents(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (contract_id, change_sequence)
);

CREATE TABLE core.field_provenance (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  field_path text NOT NULL,
  source_document_id uuid NOT NULL REFERENCES raw.source_documents(id),
  source_locator text NOT NULL,
  raw_value jsonb,
  normalized_value jsonb,
  transformation text,
  parser_version text NOT NULL,
  normalization_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (entity_type, entity_id, field_path, source_document_id, source_locator)
);

CREATE TABLE core.price_observations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  observation_type text NOT NULL CHECK (observation_type IN ('PUBLIC_CONTRACT','MARKET','CATALOG','QUOTE')),
  normalized_category text NOT NULL,
  manufacturer text,
  model text,
  specification jsonb NOT NULL DEFAULT '{}'::jsonb,
  observed_at date NOT NULL,
  currency char(3) NOT NULL,
  quantity numeric(24,6),
  unit text NOT NULL,
  unit_price numeric(24,4) NOT NULL CHECK (unit_price >= 0),
  vat_included boolean,
  shipping_included boolean,
  installation_included boolean,
  maintenance_included boolean,
  bundle_components jsonb NOT NULL DEFAULT '[]'::jsonb,
  source_document_id uuid REFERENCES raw.source_documents(id),
  source_url text,
  confidence numeric(5,4) CHECK (confidence BETWEEN 0 AND 1),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX price_observations_cohort_idx ON core.price_observations (normalized_category, unit, observed_at);

CREATE TABLE core.rule_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id text NOT NULL,
  version text NOT NULL,
  name text NOT NULL,
  description text NOT NULL,
  configuration jsonb NOT NULL,
  code_digest char(64) NOT NULL,
  status text NOT NULL CHECK (status IN ('DRAFT','SHADOW','SCHEDULED','ACTIVE','RETIRED','ROLLED_BACK')),
  effective_at timestamptz,
  retired_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (rule_id, version)
);
CREATE UNIQUE INDEX one_active_rule_version_idx ON core.rule_versions (rule_id) WHERE status = 'ACTIVE';

CREATE TABLE core.rule_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_version_id uuid NOT NULL REFERENCES core.rule_versions(id),
  run_key text NOT NULL UNIQUE,
  input_snapshot_at timestamptz NOT NULL,
  input_digest char(64) NOT NULL,
  started_at timestamptz NOT NULL,
  completed_at timestamptz,
  status text NOT NULL CHECK (status IN ('RUNNING','SUCCEEDED','FAILED','CANCELLED')),
  record_count bigint NOT NULL DEFAULT 0,
  signal_count bigint NOT NULL DEFAULT 0,
  error_detail text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE core.anomaly_signals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_run_id uuid NOT NULL REFERENCES core.rule_runs(id),
  rule_version_id uuid NOT NULL REFERENCES core.rule_versions(id),
  signal_type text NOT NULL,
  target_type text NOT NULL,
  target_id uuid NOT NULL,
  score numeric(18,8),
  severity text NOT NULL CHECK (severity IN ('INFO','LOW','MEDIUM','HIGH','CRITICAL')),
  status core.signal_status NOT NULL DEFAULT 'NEW',
  explanation jsonb NOT NULL,
  calculation jsonb NOT NULL,
  blockers jsonb NOT NULL DEFAULT '[]'::jsonb,
  comparison_digest char(64),
  assigned_user_id uuid,
  version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (rule_version_id, target_type, target_id, comparison_digest)
);
CREATE INDEX signals_status_created_idx ON core.anomaly_signals (status, created_at);
CREATE INDEX signals_target_idx ON core.anomaly_signals (target_type, target_id);
CREATE TRIGGER anomaly_signals_updated_at BEFORE UPDATE ON core.anomaly_signals FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

COMMIT;
