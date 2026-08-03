# FINAL VERIFICATION

최종 gate는 atomic하다. `FINAL_BUILD_CONTRACT.md`가 선언한 전체 범위를 clean
extraction과 같은 source에서 검증하고, 필수 항목 하나라도 실패하면 완료가 아니다.

## 권위와 진입점

- 활성 명세는 루트 `specs/` 단일 트리다.
- Git tag `authority-v13-frozen`은 불변 v13 원본과 base provenance 핀이다.
- 별도 명세 복제 트리와 루트 Manifest는 검증 입력이 아니다.
- 완성 범위와 수치는 `FINAL_BUILD_CONTRACT.md`에서만 선언한다.

## 검증 체인

- `make verify-specs`: 현재 `specs/`, frozen tag 핀, migration, acceptance source/design 계약
- `make verify-codegen`: OpenAPI/client, response, acceptance registry, UI registry 결정성
- `make build-ui`: UI 빌드 공통 경계
- `make verify-final`: spec/codegen, source, SQLx, runtime, container, recovery, UI hard gate
- `make verify-acceptance`: sealed acceptance 실행과 독립 evidence 검증

`verify-final`은 `verify-specs`와 `verify-codegen`을 포함하며, Bun 검증과 UI
E2E/visual target은 `build-ui`를 공유한다. Sealed acceptance는 별도 필수 gate다.

override가 없으면 acceptance runner는 Git이 무시하는
`artifacts/acceptance/`에 run-scoped evidence, source bundle, extraction receipt, run index와
seal을 생성하고 독립 validator로 재검증한다. `make source-archive`가 만든
배포 archive의 Manifest는 archive 내부에만 존재한다.

## Static

- frozen tag 해석과 현재 `specs/` 계약
- archive traversal/symlink과 archive-local Manifest
- exact toolchain과 lockfile
- formatter, linter, strict typecheck
- forbidden placeholder marker 0건
- 모든 screen/API/schema reference 해석
- generated OpenAPI/client, response, acceptance/UI registry deterministic diff 0건

## Database

- PostgreSQL runtime 시작과 clean migration
- runtime/spec migration set 계약
- role grant와 public/private 경계 차단
- SQLx offline metadata 현행성
- deterministic seed
- concurrency/optimistic-locking test

## Backend

- `FINAL_BUILD_CONTRACT.md`와 active specs가 선언한 모든 service binary build
- 건강·준비 상태
- 모든 외부·private operation의 exact-once exposure
- OIDC, Service/Actor Assertion, bounded step-up flow
- job/outbox/inbox/lease
- source adapter와 parser/OCR sandbox
- publication, correction/retraction, audit 무결성

## Frontend

- 모든 SvelteKit app의 Bun SSR build·startup
- `FINAL_BUILD_CONTRACT.md`가 선언한 모든 route render
- generated client-only API 경계
- wide/compact responsive state
- keyboard·screen-reader semantics
- browser Control token 0건
- SEO·cache 계약

## End-to-end

- public discovery
- case comprehension/reproduction
- signal-to-publication
- response request/submission
- correction/retraction
- source schema drift
- rule shadow/activation/rollback
- access administration
- incident/kill switch
- subscription lifecycle

## Operations

- Docker restart
- backup/restore
- source disable
- budget stop
- dead-letter recovery
- graceful shutdown
- telemetry redaction

명세가 명시적으로 not applicable로 선언하지 않은 skipped test는 실패다.
