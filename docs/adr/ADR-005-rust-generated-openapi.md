# ADR-005: Rust-generated OpenAPI와 생성 TypeScript client

- Status: Accepted
- Date: 2026-07-10

## Decision

Operational HTTP contract는 Rust DTO/Actix handler에서 Utoipa로 생성한 separate public/control/submission OpenAPI JSON이다. Hey API Fetch generator로 three separate TypeScript clients를 만든다.

## Consequences

- implementation/contract/client drift를 CI가 차단
- operation ID/schema discipline 필요
- generated artifacts commit 및 direct edit 금지
- generation은 DB/network independent

## Rejected

- operational YAML을 사람이 계속 수정
- handwritten fetch/DTO
- combined public/control/submission client
