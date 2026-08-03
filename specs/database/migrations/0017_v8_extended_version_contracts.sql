BEGIN;

ALTER TABLE core.rule_versions ADD COLUMN row_version bigint NOT NULL DEFAULT 1 CHECK (row_version > 0);
ALTER TABLE ops.jobs ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0);
ALTER TABLE ops.notifications ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0);
ALTER TABLE ops.user_roles ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0);

CREATE INDEX rule_versions_row_version_idx ON core.rule_versions(id, row_version);
CREATE INDEX jobs_version_idx ON ops.jobs(id, version);
CREATE INDEX source_runs_version_idx ON ops.source_runs(id, version);
CREATE INDEX notifications_user_version_idx ON ops.notifications(user_id, id, version);
CREATE INDEX user_roles_version_idx ON ops.user_roles(user_id, role_id, version) WHERE revoked_at IS NULL;

COMMIT;
