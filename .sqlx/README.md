# SQLx offline metadata

Compile-time `sqlx::query!`, `query_as!`, and `query_scalar!` calls are checked
against the migrated PostgreSQL 18.4 schema. Their `query-*.json` metadata is
committed here so database-free builds use the workspace's offline default.

Regenerate metadata after changing a macro query or migration:

```bash
scripts/dev-db.sh up
scripts/dev-db.sh migrate
SQLX_OFFLINE=false DATABASE_URL="$(scripts/dev-db.sh url)" \
  cargo sqlx prepare --workspace -- --all-targets
scripts/dev-db.sh down
```

`make test-sqlx-prepare` creates a clean migrated database and requires an
online `cargo sqlx prepare --workspace --check -- --all-targets` diff check to
pass. `.cargo/config.toml` makes ordinary host Cargo commands offline by default;
an explicit process environment value still overrides it. Runtime query APIs
remain only for validated dynamic SQL and documented schema mismatches that
cannot be represented by compile-time macros.
