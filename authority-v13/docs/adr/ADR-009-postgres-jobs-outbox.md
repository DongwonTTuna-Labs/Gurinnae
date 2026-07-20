# ADR-009: PostgreSQL durable jobs와 transactional outbox

- Status: Accepted
- Date: 2026-07-10

## Decision

초기 queue와 event delivery는 PostgreSQL durable jobs, lease/fencing, transactional outbox/inbox로 구현한다. Delivery는 at-least-once이며 consumer는 idempotent하다.

## Rationale

현재 예상 규모에서 domain transaction과 원자성을 유지하면서 별도 broker 운영 복잡도를 피한다.

## Reconsideration trigger

측정된 throughput/latency/retention 또는 cross-region 요구가 PG 경계를 넘을 때 broker/workflow engine ADR을 작성한다.
