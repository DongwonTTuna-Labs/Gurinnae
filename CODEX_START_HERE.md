# CODEX START HERE — 구린네 전체 구현

이 작업은 계획서만 작성하는 요청이 아니다. 현재 monorepo와 활성 `specs/`를
읽고 `FINAL_BUILD_CONTRACT.md`의 **전체 운영 가능 source tree**를 구현한다.

## 권위 모델

- 현재 명세는 루트 `specs/` 단일 트리에서만 읽는다.
- Git tag `authority-v13-frozen`은 불변 v13 원본과 base provenance를 검증하는 기준이다.
- tag를 별도 디렉터리로 풀어 활성 명세와 병행 사용하지 않는다.
- 루트 Manifest 파일은 권위·검증 입력이 아니다.

## 읽기 순서

1. `AGENTS.md`
2. `FINAL_BUILD_CONTRACT.md`
3. `specs/product/final-product-contract.yaml`
4. `specs/domain/state-machines.yaml`
5. `specs/api/operation-contracts.yaml`
6. `specs/application/command-semantics.yaml`
7. `specs/api/operation-persistence.yaml`
8. `specs/auth/`, `specs/cryptography/`
9. `specs/database/`, `specs/events/`
10. `specs/parsers/`, `specs/agents/`, `specs/connectors/`, `specs/detection/`
11. `specs/ui/`
12. `tests/acceptance/`

`AGENTS.md`의 권위 순서를 준수하고, 수정 전에 영향받는 명세를 전체 읽는다.

## 시작 전 검증

```bash
python3 --version  # CPython 3.13.5
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --require-hashes -r requirements-spec.txt
git rev-parse 'authority-v13-frozen^{commit}'
make verify-specs
make verify-codegen
make build-ui
```

## 구현 필수 범위

- 완성 범위와 수치는 `FINAL_BUILD_CONTRACT.md`를 단일 기준으로 삼는다.
- 모든 선언된 Cargo/Bun workspace, service, migration, operation, screen을 구현한다.
- 모든 command의 transaction·idempotency·audit·0..N event semantics를 보존한다.
- PostgreSQL migration, RLS·immutable record·service role·replay protection을 명세대로 구현한다.
- request-bound Service/Actor Assertion과 bounded step-up authorization을 구현한다.
- exact encrypted cookie/field envelope와 key rotation을 구현한다.
- 명세의 exact parser/OCR 선택과 sandbox를 구현하고 generic text extractor로 대체하지 않는다.
- 선언된 read-only Agent, typed tool, connector, rule와 평가 계약을 구현한다.
- Docker development/test/production topology, backup/restore, graceful shutdown, observability,
  security, accessibility를 구현한다.

Rust·Svelte 구현은 `AGENTS.md`의 Rustful/Svelteful, SOLID, YAGNI, Clean Code,
파일·함수 크기와 계층 경계를 지킨다. Service/Actor Assertion, bounded retry grant,
encrypted envelope와 PostgreSQL replay protection을 간소한 browser-cookie Control API로
대체하지 않는다.

## 금지

- `unsafe`, 직접 FFI, production `unwrap`/`expect`/`panic!`
- `todo!`, `unimplemented!`, `unreachable!`; 모든 crate root의 `#![forbid(unsafe_code)]` 누락
- MVP·일부 구현·placeholder·501·mock-only 완료 보고
- Public/Control/Submission/Identity 경계 통합
- generic JSON payload 또는 stringly typed state
- acceptance 삭제·완화·skip
- source key·cookie·token·브라우저 profile·auth seed·live private data 포함
- 실제 기관·업체를 합성 fixture에 사용

AI와 규칙 엔진은 부패·범죄를 자동 확정하지 않는다. evidence, 소명권,
사람의 publication 승인, immutable revision, correction·retraction 불변식을 보존한다.
명세와 권위 순서 안에서 구현 세부를 해결하고, 중간 승인을 요청하거나
기다리느라 완성 범위를 중단하지 않는다.

## 검증 모델

- `make verify-specs`: 현재 `specs/`, frozen tag 핀, migration, acceptance source/design 계약
- `make verify-codegen`: OpenAPI/client, response, acceptance registry, UI registry 결정성
- `make build-ui`: UI 빌드 공통 경계
- `make verify-final`: spec/codegen, source, SQLx, runtime, container, recovery, UI hard gate
- `make verify-acceptance`: sealed acceptance 실행과 독립 evidence 검증

Acceptance override가 없으면 Git이 무시하는 `artifacts/acceptance/`에 run-scoped
evidence와 source bundle/extraction receipt를 만든다. 배포 archive는
`make source-archive`로 `artifacts/`에 만들고, 무결성 Manifest는 archive 내부에만 둔다.

## 제출 형식

모든 hard gate가 통과했을 때만 다음을 제출한다.

- 완전한 source tree와 검증된 `source/` tree archive
- archive-local Manifest, `VERIFY.md`, 실제 `VERIFICATION.md`
- Cargo.lock, bun.lock, `.sqlx/`, generated OpenAPI/client
- Docker/CI/backup/restore와 실제 테스트 증거

Leading verdict는 성공 시에만 `VERDICT: ARTIFACT_READY`, 그 외에는
`VERDICT: CHANGES_REQUIRED`다. 실패한 경우 정확한 failed gate를 명시한다.
