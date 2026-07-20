# 구린네 — Codex Final Authority Pack v13.0.0

구린네는 대한민국 공공기관·지자체·공공기관의 공개 계약·예산·조달 자료에서 **조사할 가치가 있는 이상 징후**를 찾고, 확인 사실·중요한 미확인·당사자 소명·반대 근거·원본 provenance·정정 이력과 함께 공개하는 증거 우선 플랫폼이다.

이 저장소는 애플리케이션 구현본이 아니라, Codex가 제품·화면·API·DB·권한·Agent·Connector·운영 정책을 다시 발명하지 않고 **하나의 완전한 source tree**를 구현하기 위한 최종 권위 사양이다.

## 고정 기술

- Rust `1.97.0`, edition 2024, first-party `unsafe` 0건
- Actix Web `4.14.0`, Tokio, SQLx `0.9.0`
- PostgreSQL `18.4`
- Svelte 5, SvelteKit SSR, Bun `1.3.14`
- TypeScript `5.9.3` strict, Biome `2.5.3`, Valibot `1.1.0`
- Rust-generated OpenAPI → generated Fetch clients
- Cargo+Bun monorepo, Docker Compose

## 최종 권위 범위

| 항목 | 수량 |
|---|---:|
| 화면 | **94** |
| Public / Submission / Control / Browser Identity operation | **41 / 34 / 131 / 6** |
| 외부 operation 합계 | **212** |
| Private Identity operation | **9** |
| Query / Command / HTTP non-GET write | **107 / 105 / 102** |
| PostgreSQL migration / active table / active function | **24 / 107 / 72** |
| Optimistic-concurrency contract | **64** |
| Cargo workspace member / Bun workspace | **32 / 9** |
| Compose service | **20** |
| Agent / read-only tool / evaluation | **5 / 9 / 50** |
| Connector / upstream operation | **6 / 44** |
| Detection rule / evaluation | **10 / 300** |
| Acceptance feature / scenario | **35 / 271** |

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

1. `CODEX_HANDOFF.md`
2. `CODEX_START_HERE.md`
3. `AGENTS.md`
4. `FINAL_BUILD_CONTRACT.md`
5. `VERIFY.md`

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --require-hashes -r requirements-spec.txt
PYTHONDONTWRITEBYTECODE=1 make final-check
make verify-postgres-runtime
PYTHONDONTWRITEBYTECODE=1 make final-check
sha256sum --check MANIFEST.sha256
```

Codex는 내부적으로 반복 구현·빌드·수정을 수행할 수 있다. 그러나 최종 제출은 MVP, scaffold, fixture-only, 일부 화면 또는 계획이 아니라 전체 hard gate를 통과한 완전한 source archive 하나여야 한다.
