# Final PostgreSQL / SQLx Database Contract

상태: **FINAL**

## Migration order

1. `0001_extensions_schemas_types.sql`
2. `0002_raw_and_core.sql`
3. `0003_editorial_and_intake.sql`
4. `0004_ops_and_public_projection.sql`
5. `0005_roles_grants_and_seed.sql`

실제 source tree에서는 동일 SQL을 `db/migrations/<timestamp>_<name>.sql`로 materialize하고
SQLx migrator가 적용한다.

## Schema boundaries

- `raw`: immutable source fetch/document/parsed payload
- `core`: normalized procurement entities, provenance, rules and signals
- `editorial`: investigation, evidence, claim, response, review and publication
- `intake`: untrusted external submissions and token-scoped drafts
- `ops`: users, RBAC, jobs, events, incidents, audit and cost
- `public`: approved public projection only

## Non-negotiable

- API startup does not auto-run migrations.
- public API role cannot access private schemas.
- external submission role cannot update editorial/public tables.
- all versioned commands use `WHERE version = expected_version`.
- state change and outbox event commit in one transaction.
- job lease uses fencing tokens.
- sensitive text is encrypted before persistence.
- SQLx offline metadata is committed and checked.
