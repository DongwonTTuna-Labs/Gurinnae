# FINAL VERIFICATION

The final gate is atomic. Every check must pass in the delivered archive after a clean extraction.

## Static

- manifest
- archive traversal/symlink
- exact toolchain and lock
- formatter/linter/typecheck
- no forbidden placeholder markers
- all screen/API/schema references resolve

## Database

- PostgreSQL 18.4 starts
- all migrations up/down policy verified
- role grants deny public/private crossing
- SQLx offline metadata current
- seed is deterministic
- concurrency/optimistic locking tests

## Backend

- all service binaries build
- health/readiness
- all 205 external HTTP operations and 9 private internal-identity operations exposed exactly once
- OIDC flows conform
- jobs/outbox/inbox/lease tests
- source adapters
- publication gate
- correction/retraction
- audit integrity

## Frontend

- three apps build and start under Bun
- 94 routes render
- generated clients only
- desktop/tablet/mobile states
- keyboard and screen-reader semantics
- no control token in browser
- SEO and caching

## End-to-end

- public discovery
- case comprehension/reproduction
- signal to publication
- response request/submission
- correction and retraction
- source schema drift
- rule shadow/activation/rollback
- access administration
- incident and kill switch
- subscription lifecycle

## Operations

- Docker restart
- backup/restore
- source disable
- budget stop
- dead-letter recovery
- graceful shutdown
- telemetry redaction

A skipped test is a failure unless the specification explicitly marks it not applicable.
