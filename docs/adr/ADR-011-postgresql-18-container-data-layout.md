# ADR-011 — PostgreSQL 18 official container data layout

- Status: Accepted
- Date: 2026-07-10
- Decision owners: data platform, developer platform

## Context

The official PostgreSQL image changed its data-directory contract for major version 18. `PGDATA` is version-specific and the declared volume moved from the legacy `/var/lib/postgresql/data` path to `/var/lib/postgresql`. Reusing the old mount can lead to surprising persistence and upgrade behavior.

## Decision

All Gurine PostgreSQL 18.4 Compose definitions set:

```text
PGDATA=/var/lib/postgresql/18/docker
```

Persistent volume and test tmpfs targets are:

```text
/var/lib/postgresql
```

The legacy `/var/lib/postgresql/data` target is forbidden. Production deployment manifests must preserve the same logical contract even when a managed PostgreSQL service replaces the container.

## Migration guard

A developer with an existing pre-18 or legacy-path local volume must not attach it blindly. The migration runbook must export/verify/restore or create a new volume. Automated deletion of an unknown local volume is forbidden.

## Verification

Static validation checks Compose and the machine-readable container matrix. Runtime smoke writes a sentinel row, recreates the PostgreSQL container without deleting the named volume, and confirms the row remains. Test Compose uses tmpfs at the new volume root.
