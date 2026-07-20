# Implementation Plan Contract

이 문서는 단계별 납품 로드맵이 아니라 구현자가 전체 결과를 완성하기 위해 사용하는 내부 의존성 순서다.
어느 항목도 별도 최종 산출물로 간주하지 않는다.

1. repository/toolchain materialization
2. PostgreSQL migrations, roles, seed and synthetic fixtures
3. domain/application/persistence layers
4. jobs, outbox, ingestion, normalization, detection
5. public/control/submission APIs
6. Rust OpenAPI generation and generated clients
7. three SvelteKit SSR applications and all 94 screens
8. identity, email, object storage and connector adapters
9. publication/correction/retraction and operations
10. Docker/CI/observability/backups
11. full verification

구현자는 병렬화할 수 있지만 최종 제출 전에 모든 항목이 통합돼야 한다.
