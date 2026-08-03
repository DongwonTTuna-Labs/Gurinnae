# VERIFY — 구린네 monorepo

이 문서는 현재 source tree와 활성 명세, 생성물, runtime, UI, acceptance evidence를
검증하는 진입점을 정의한다. 완성 범위와 모든 제품 수치의 단일 기준은
`FINAL_BUILD_CONTRACT.md`다.

## 지원 환경

- CPython `3.13.5`
- Rust `1.97.0`
- Bun `1.3.14`
- PostgreSQL `18.4`
- Docker/Compose

Python 명세 도구는 hash-pinned `requirements-spec.txt`로 격리한다.

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --require-hashes -r requirements-spec.txt
```

## 권위 모델

현재 명세는 루트 `specs/` 단일 트리에서 검증한다. Git tag
`authority-v13-frozen`은 불변 v13 원본과 base provenance 핀이다. 별도
체크아웃 디렉터리나 루트 Manifest는 활성 권위·검증 입력이 아니다.

```bash
git rev-parse 'authority-v13-frozen^{commit}'
```

tag는 Git object database에서 읽고 현재 worktree에 복제하지 않는다. tag가 없거나
예상한 commit으로 해석되지 않으면 fail-closed한다.

## 명세 검증

```bash
PYTHONDONTWRITEBYTECODE=1 make verify-specs
```

`verify-specs`는 현재 `specs/` 트리의 정적·의미 계약, frozen tag 핀, runtime/spec
migration 집합, acceptance source/design 계약을 검증한다. YAML·JSON duplicate key,
API·DB·UI·traceability 연결, 인증·암호화·parser·agent·connector·rule 계약,
secret pattern과 금지 경로도 이 경계에서 fail-closed한다.

PostgreSQL reference runtime만 독립적으로 재확인할 때는 다음을 실행한다.

```bash
make verify-postgres-runtime
```

임시 runtime 결과를 committed baseline과 비교하고 clean migration, catalog, privilege,
RLS, audit, lifecycle, concurrency와 submission session canary를 검증한다.

Parser/OCR reference harness만 독립적으로 재확인할 때는 다음을 실행한다.

```bash
PYTHONDONTWRITEBYTECODE=1 python -B specs/parsers/reference_harness.py \
  --json-output /tmp/gurine-parser-reference.json
```

## Code generation

```bash
make verify-codegen
```

`verify-codegen`은 Rust-generated OpenAPI와 Fetch client, generated response, acceptance registry,
typed UI registry를 재생성 가능한 형태로 검증한다. generated file을 직접 수정하거나
재생성 diff를 성공으로 취급하지 않는다.

## UI build

```bash
make build-ui
```

`build-ui`는 Bun/SvelteKit SSR 빌드의 공통 경계다. `verify-final`의 Bun 검증,
E2E, visual target은 이 경계를 공유하여 같은 source에 대한 UI build를 중복하지 않는다.

## 최종 source/runtime gate

```bash
make verify-final
```

`verify-final`은 `verify-specs`, `verify-codegen`, Rust workspace·SQLx, Bun/UI, PostgreSQL·service
runtime, container/network, backup/restore, E2E·visual/accessibility를 하나의 종속성 체인으로
검증한다. skipped, weakened, focused, placeholder test는 통과로 간주하지 않는다.

## Sealed acceptance evidence

```bash
make verify-acceptance
```

Acceptance는 `verify-final`과 별도의 필수 완료 gate다. override가 없으면 runner가
Git이 무시하는 `artifacts/acceptance/`에 고유한 run 디렉터리, source bundle,
extraction receipt, scenario receipt, run index와 seal을 생성한다. source commit/tree 바인딩과
artifact digest를 자동 파생하고 독립 evidence validator로 재검증한다. 명시적
override는 release workflow의 외부 evidence/archive 바인딩을 보존한다.

## Source archive

```bash
make source-archive
make clean-extraction-verify
```

Source archive는 `artifacts/`에 생성되고 clean extraction에서 재검증된다. 무결성
Manifest는 archive 내부에만 생성되며 루트 source tree에 지속하지 않는다.

`verify-final`, `verify-acceptance`, 필요한 archive 검증 중 하나라도 미실행·실패하면
`ARTIFACT_READY`로 판정하지 않는다.
