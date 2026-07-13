# ADR-001: Gurine v3 기준 기술 스택과 서비스 경계

- Status: Accepted
- Date: 2026-07-10
- Supersedes: ADR-001 v1 decision (`axum` + production Python pipeline + manually maintained operational OpenAPI)
- Decision owners: Product/Architecture

## Context

구린네는 공개 read surface, 권한이 강한 editorial command surface, 외부 당사자 submission surface, 장기 실행 data jobs, 재현 가능한 rule engine, SSR web을 함께 가진다. v1의 Rust/Python 혼합은 domain/schema를 양쪽에 복제하고 Codex가 서로 다른 언어에서 정책을 다르게 구현할 위험이 컸다. API와 프런트엔드의 수동 contract도 drift 위험이 있었다.

사용자는 Rust/SQLx/Actix, TypeScript/Bun/Biome/SvelteKit SSR, Rust-generated OpenAPI와 generated client, PostgreSQL 최신 안정 버전, Docker 개발환경, monorepo를 명시적으로 선택했다.

## Decision

- production backend와 background jobs는 Rust-first다.
- HTTP는 Actix Web.
- non-HTTP worker/scheduler는 Tokio binaries.
- 모든 PostgreSQL 접근은 SQLx.
- PostgreSQL 18.4, local/CI exact image.
- public/control/submission API는 별도 binary, DB role, OpenAPI, client, deployment.
- Rust DTO/handlers에서 Utoipa로 OpenAPI 3.1 JSON을 생성.
- Hey API로 Fetch TypeScript clients 생성.
- frontend는 TypeScript strict + SvelteKit SSR 앱 세 개(public, review, response).
- Bun은 package manager, scripts, build, SSR runtime.
- Biome + svelte-check.
- Cargo workspace + Bun workspaces + Make/xtask.
- Docker Compose DB-only/full-container.
- production Python runtime은 별도 ADR 없이는 금지.

## Consequences

Positive:

- domain/state/policy 타입을 Rust에서 공유
- public/control/submission boundary를 compile/DB/deploy로 강화
- API/client drift 자동 차단
- single toolchain for ingestion/rules/jobs/API
- SQLx compile-time query validation
- Docker/lockfile 재현성

Costs:

- Rust parser/data library 구현 비용
- codegen pipeline과 workspace discipline
- community Bun adapter compatibility gate
- 여러 binary/container 운영

## Rejected alternatives

### v1 `axum` + Python pipeline

유효한 구조였지만 사용자의 확정 기술 방향과 다르고, 이 프로젝트에서는 cross-language domain/contract drift가 더 큰 위험이다.

### Python monolith

초기 개발은 빠르지만 locked stack, command safety, shared domain 목표와 불일치.

### Node-only full stack

Bun/Svelte와 일관되지만 durable data/rule/API core의 Rust 결정과 불일치.

### One Actix API containing public, control and submission

DB/client/network 경계가 약해져 거부.

### Kafka/Kubernetes/Temporal at baseline

측정된 필요 없는 운영 복잡도.

## Fitness tests

- Cargo dependency graph has no axum.
- production workspace contains no Python runtime.
- domain has no Actix/SQLx/Utoipa.
- public DB role private reads fail.
- public/control/submission OpenAPI and clients are separate.
- clean regeneration produces no diff.
- PostgreSQL 18.4 SQLx checks pass.
- Bun SSR production smoke passes.
