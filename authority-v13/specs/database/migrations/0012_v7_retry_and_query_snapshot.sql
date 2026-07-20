BEGIN;

CREATE TABLE ops.job_query_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_user_id uuid NOT NULL REFERENCES ops.users(id),
  query_kind text NOT NULL CHECK (query_kind = 'JOB_RETRY_SELECTION'),
  normalized_filter jsonb NOT NULL,
  selected_job_ids uuid[] NOT NULL,
  selected_count integer GENERATED ALWAYS AS (cardinality(selected_job_ids)) STORED,
  snapshot_sha256 char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL,
  CHECK (cardinality(selected_job_ids) > 0),
  CHECK (expires_at > created_at)
);
CREATE INDEX job_query_snapshots_actor_expiry_idx
  ON ops.job_query_snapshots (actor_user_id, expires_at DESC);

ALTER TABLE ops.source_runs
  ADD COLUMN retry_of_source_run_id uuid REFERENCES ops.source_runs(id);

CREATE INDEX source_runs_retry_of_idx
  ON ops.source_runs (retry_of_source_run_id)
  WHERE retry_of_source_run_id IS NOT NULL;

REVOKE ALL ON ops.job_query_snapshots FROM PUBLIC;
GRANT SELECT, INSERT ON ops.job_query_snapshots TO gurine_control_api;

COMMIT;
