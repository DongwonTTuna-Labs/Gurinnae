# SQLx offline metadata

The workspace deliberately uses runtime-checked `sqlx::query`, `query_as`, and
`query_scalar` calls rather than compile-time query macros. Consequently,
`cargo sqlx prepare --workspace` produces zero `query-*.json` files. The final
gate verifies that this directory exists, that no macro query is present, and
that all runtime queries execute against a clean PostgreSQL 18.4 database.
