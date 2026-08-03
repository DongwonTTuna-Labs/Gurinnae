# 구린네 — 전체 제품 monorepo v13

구린네는 대한민국 공공기관·지자체·공공기관의 공개 계약·예산·조달 자료에서 **조사할 가치가 있는 이상 징후**를 찾고, 확인 사실·중요한 미확인·당사자 소명·반대 근거·원본 provenance·정정 이력과 함께 공개하는 증거 우선 플랫폼이다.

이 저장소는 제품 소스, 테스트, 운영 스크립트와 활성 명세를 함께 보존하는 하나의
완전한 monorepo다. 현재 권위 명세는 루트 `specs/`에만 있으며, 별도 복제본을
활성 명세로 취급하지 않는다.

## 고정 기술

- Rust `1.97.0`, edition 2024, first-party `unsafe` 0건
- Actix Web `4.14.0`, Tokio, SQLx `0.9.0`
- PostgreSQL `18.4`
- Svelte 5, SvelteKit SSR, Bun `1.3.14`
- TypeScript `5.9.3` strict, Biome `2.5.3`, Valibot `1.1.0`
- Rust-generated OpenAPI → generated Fetch clients
- Cargo+Bun monorepo, Docker Compose

## 권위와 완성 범위

- 활성 명세: 루트 `specs/` 단일 트리
- 불변 v13 원본: Git tag `authority-v13-frozen`
- 완성 범위와 수치의 단일 기준: `FINAL_BUILD_CONTRACT.md`

Git tag는 base provenance와 불변 원본 비교용이다. 별도 체크아웃을
두 번째 활성 명세로 사용하지 않으며, 루트 Manifest도 권위 모델이 아니다.

## 내부 인증 경계

```text
Browser
→ Review Console SvelteKit BFF
   - encrypted host-only session cookie
   - synchronizer CSRF
   - typed action authorization descriptor for STEP_UP operations

→ Private Rust Identity API
   - request-bound Service Assertion 검증
   - session 해석
   - OIDC state·nonce·PKCE
   - bounded step-up authorization claim
   - request-bound Actor Assertion 발급

→ Control API
   - X-Gurine-Actor-Assertion만 수신
   - browser cookie·CSRF·raw authorization 수신 금지
```

고위험 command의 step-up authorization은 session, canonical action digest와 Idempotency-Key에 결합되며 5분 동안 최대 세 개의 fresh single-use Actor Assertion을 발급한다. Callback은 Actor Assertion을 직접 발급하지 않는다.

## 문서 추출·암호화

- Session, step-up transaction, step-up authorization, DB field envelope: ChaCha20-Poly1305 IETF
- CSV, XML, XLSX, DOCX, HWPX, digital PDF, scanned PDF 지원
- PDF OCR: sandboxed `pdftoppm` + Tesseract `kor`/`eng`
- Binary `.hwp`: automatic parsing 금지, trusted PDF/HWPX conversion 전 quarantine
- XXE, ZIP traversal/bomb, 과대·암호화·손상 파일 fail-closed
- 모든 추출 결과에 page/cell/paragraph/locator provenance 보존

## 시작

1. `CODEX_START_HERE.md`
2. `AGENTS.md`
3. `FINAL_BUILD_CONTRACT.md`
4. `VERIFY.md`

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --require-hashes -r requirements-spec.txt
git rev-parse 'authority-v13-frozen^{commit}'
make verify-specs
make verify-codegen
make build-ui
make verify-final
```

`verify-specs`는 현재 `specs/` 트리와 frozen tag 핀, migration, acceptance 소스
계약을 검증한다. `verify-codegen`은 OpenAPI/client, acceptance registry, UI 생성물의
결정성을 검증하고 `build-ui`는 UI build의 공통 경계다. `verify-final`은
이 검증과 source, runtime, container, recovery, UI hard gate를 묶는다.

Sealed acceptance는 별도 `make verify-acceptance`로 실행한다. override가 없으면
Git이 무시하는 `artifacts/acceptance/`에 run-scoped evidence와 검증용 source bundle을
만든다. 배포용 archive는 `make source-archive`가 `artifacts/`에 만들며,
Manifest는 압축 내부에만 생성된다.

최종 제출은 MVP, scaffold, fixture-only, 일부 화면 또는 계획이 아니라
`FINAL_BUILD_CONTRACT.md`의 전체 범위와 모든 필수 gate를 통과한 source tree여야 한다.
