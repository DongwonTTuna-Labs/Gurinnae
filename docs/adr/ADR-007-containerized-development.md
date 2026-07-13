# ADR-007: Docker 기반 개발환경

- Status: Accepted
- Date: 2026-07-10

## Decision

DB-only Docker + host tools와 full-container Compose를 모두 지원한다. Exact image tag와 release digest를 사용하고 one-shot migrator를 둔다.

## Rationale

- SQLx/PG exact behavior
- onboarding/reproducibility
- production image early verification
- fast host feedback loop 유지

## Rejected

- only host-installed PostgreSQL
- only full container hot reload
- latest image tags
- migration in API startup
