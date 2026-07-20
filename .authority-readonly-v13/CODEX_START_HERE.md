# CODEX START HERE — 구린네 전체 구현

이 작업은 계획서만 작성하는 요청이 아니다. 이 authority pack을 읽고 **전체 운영 가능 source tree**를 구현한다.

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

## 시작 전 authority 검증

```bash
python3 --version  # CPython 3.13.5
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --require-hashes -r requirements-spec.txt
PYTHONDONTWRITEBYTECODE=1 python -B scripts/validate_final_spec.py --strict
make verify-postgres-runtime
PYTHONDONTWRITEBYTECODE=1 python -B scripts/validate_final_spec.py --strict
sha256sum --check MANIFEST.sha256
```

## 구현 필수 범위

- 32 Cargo member와 9 Bun workspace
- 세 SvelteKit SSR 앱과 94 화면
- 외부 operation 212 + private Identity operation 9
- 105 command의 transaction·idempotency·audit·0..N event semantics
- PostgreSQL 24 migration, 107 active table, RLS·immutable record·service role
- request-bound Service/Actor Assertion과 bounded step-up authorization
- exact encrypted cookie/field envelopes와 key rotation
- CSV/XML/XLSX/DOCX/HWPX/PDF/OCR sandbox
- 5 read-only Agent, 9 tool, provider-double evaluation 50
- 6 source connector, 44 upstream operation
- 10 detection rule, 300-case independent oracle comparison
- Docker development/test/production topology와 20 service
- backup/restore, graceful shutdown, observability, security, accessibility

## 금지

- `unsafe`, 직접 FFI, production `unwrap`/`expect`/`panic!`
- MVP·일부 구현·placeholder·501·mock-only 완료 보고
- Public/Control/Submission/Identity 경계 통합
- generic JSON payload 또는 stringly typed state
- acceptance 삭제·완화·skip
- source key·cookie·token·브라우저 profile 포함
- 실제 기관·업체를 합성 fixture에 사용

## 제출 형식

모든 hard gate가 통과했을 때만 다음을 제출한다.

- 완전한 `source/` tree archive
- `MANIFEST.md`, `MANIFEST.sha256`, `VERIFY.md`, 실제 `VERIFICATION.md`
- Cargo.lock, bun.lock, `.sqlx/`, generated OpenAPI/client
- Docker/CI/backup/restore와 실제 테스트 증거

Leading verdict는 성공 시에만 `VERDICT: ARTIFACT_READY`, 그 외에는 `VERDICT: CHANGES_REQUIRED`다.
