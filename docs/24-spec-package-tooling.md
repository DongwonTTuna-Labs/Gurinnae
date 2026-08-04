# 명세 도구와 production runtime의 구분

## 1. 목적

이 monorepo는 JSON Schema, fixture, OpenAPI, migration, acceptance 계약을 제품 소스와
함께 검증한다. 명세 검증을 위해 작은 Python 스크립트를 제공하지만 이는
production runtime에 Python service를 허용하는 근거가 아니다.

## 2. 명세 권위

- 활성 명세는 루트 `specs/` 단일 트리에 있다.
- Git tag `authority-v13-frozen`은 불변 v13 원본과 base provenance 비교용이다.
- tag는 Git object database에서 읽고 별도 복제 트리로 활성화하지 않는다.
- 루트 Manifest는 명세 권위 또는 검증 입력이 아니다.

완성 범위와 제품 수치는 `FINAL_BUILD_CONTRACT.md`를 단일 기준으로 삼는다.

## 3. 허용 도구

```text
scripts/validate_final_spec.py
scripts/git_authority.py
scripts/verify_migrations.py
scripts/validation/
requirements-spec.txt
```

이 도구는 명세·reference·fixture·codegen 계약 검증용이다. 다음 의미가 아니다.

- production Python service 허용
- ingestion/analysis Python worker 허용
- Python domain model 허용
- production runtime dependency 허용

## 4. Production 금지

최종 Cargo/Bun workspace의 다음 경로에 Python runtime을 추가하지 않는다.

```text
apps/
services/
crates/
packages/
infra/runtime images
```

후속 ML/OCR library로 Python이 꼭 필요하면 별도 ADR에서 network/DB/write/publication
권한이 없는 isolated sidecar 계약을 설계하고 사람 승인을 받아야 한다.

## 5. 검증 경계

- `make verify-specs`: 현재 `specs/`, frozen tag 핀, migration, acceptance source/design 계약
- `make verify-codegen`: OpenAPI/client, response, acceptance registry, UI registry 결정성
- `make build-ui`: UI 빌드 공통 경계
- `make verify-final`: sealed acceptance를 포함한 전체 단일 개발자 hard gate
- `make verify-acceptance`: sealed acceptance 실행과 독립 evidence 검증

명세 validator는 실제 Rust/Bun/Docker runtime gate를 대신하지 않는다. `verify-prearchive`는
archive가 없어도 실행 가능한 소스·runtime 체인을 소유하고, `verify-final`은 그 체인과
`verify-acceptance`를 모두 직접 요구한다.

## 6. Acceptance 기본 artifact

`make verify-acceptance`는 evidence root, run ID, source commit/tree digest, source archive,
extraction receipt와 receipt digest의 일곱 입력을 모두 명시적으로 요구한다. release workflow는
`verify-prearchive` → `source-archive` → `clean-extraction-verify` → `verify-acceptance` 순서로
실행한다. 고정 출력은 `artifacts/gurine-source-v13.0.0.tar.gz`, 그 `.sha256` sidecar와
`artifacts/gurine-source-v13.0.0.extraction-receipt.json`이다. 마지막 단계는 이를
`artifacts/acceptance/`의 새 run-scoped evidence에 바인딩하고 별도 읽기 전용 컨테이너가
증거를 재검증한다.

## 7. Archive-local Manifest

`make source-archive`는 `artifacts/`의 archive 내부에만 deterministic Manifest를 생성한다.
Manifest는 package-relative file hash를 기록하고 fresh extraction에서 재검증하며,
timestamp를 넣지 않는다. 루트 source tree에 Manifest를 유지하거나 frozen tag 비교를
대체하는 용도로 사용하지 않는다.

Archive-local SHA-256와 Manifest는 archive bytes/member set의 무결성을 검증하지만 producer
identity를 인증하지 않는다. clean extraction은 추출본 안의 `scripts/git_authority.py`로
추출본 manifest를 검증하므로 archive 제작자는 그 pin 상수와 manifest를 함께 바꿀 수 있다.
따라서 fallback 위조를 거부할 수 있다는 보증은 archive 밖에서 별도로 보유한 정품
`scripts/git_authority.py`와 그 pin으로 검증하는 경우에만 성립한다. 추출본만 신뢰하는
검증자에게 producer authenticity나 암호학적 위조 불가능성을 보증하지 않는다.

Git checkout에서 검증할 때는 `authority-v13-frozen` 태그가 반드시 존재해야 한다. CI checkout은
`fetch-depth: 0`과 `fetch-tags: true`를 사용하며, origin에 태그가 없으면 감독자가
`git push origin authority-v13-frozen`으로 먼저 게시해야 한다.

## 8. Dependency

Spec tooling dependency는 `requirements-spec.txt`에 hash-pinned된다. 이 dependency는 production
SBOM/runtime에 포함하지 않는다.
