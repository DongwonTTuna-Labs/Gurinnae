# PdM 독립 재리뷰 — 최신 current worktree

검토 기준은 첨부 v13 권위 ZIP SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`과 현재
source/evidence뿐이다. 이전 버전·별도 Gurinnae 자료·이전 리뷰 verdict는
판정 근거로 사용하지 않았다. 구현 파일은 수정하지 않고 이 문서만 갱신했다.

이번 snapshot에서 `scripts/generate_pdm_flow_evidence.py::source_digest()`는
`27cdb1178b2015f64c8e1747071836b64a20bac710546857f55760ed8d6d1aa8`을 반환한다.
반면 모든 `implementation-evidence/runtime-journey-receipts/flow-01..10` 및
PDM-003 receipt는 `888a6d75253412dd881e23c38c4323b86e345d983070a7942a8203c1152b7723`을
기록한다. 현재 `sha256sum --check MANIFEST.sha256`도
`apps/review-console/src/routes/internal/operations/budgets/screen.ts`에서
실패한다.

## Verdict

```text
PDM_VERDICT: CHANGES_REQUIRED
```

화면 순서를 authority와 맞추려는 수정과 PostgreSQL flow receipt는 확인되지만,
현재 source snapshot에 결속된 release evidence와 핵심 사용자 운영 여정이 닫히지
않아 PdM LGTM을 발행할 수 없다.

## Blocking findings

### PDM-FINAL-R2-001 — source/evidence/MANIFEST freeze가 다시 깨짐 (P0)

현재 source digest는 `27cdb117…`, flow/PDM-003 receipt digest는
`888a6d752…`로 서로 다르다. `sha256sum --check MANIFEST.sha256`는 현재
`apps/review-console/src/routes/internal/operations/budgets/screen.ts`를
포함한 mismatch로 실패한다. 따라서 receipt의 `pass: true`와 PostgreSQL
journey 결과가 현재 archive에서 실행 가능한 코드의 결과임을 재현할 수 없다.
구현을 멈춘 단일 snapshot에서 flow/CAS/PDM evidence, MANIFEST, tree digest와
archive clean-extraction parity를 함께 재생성해야 한다.

### PDM-FINAL-R2-002 — 439 acceptance sealed evidence가 없음 (P0)

`Makefile:101-140`의 `run-acceptance-439`/`verify-execution-evidence`는
`ACCEPTANCE_EVIDENCE_ROOT`, run id, source commit/tree digest, archive,
extraction receipt와 sidecar를 모두 필수로 한다. 현재 이 환경 변수들이 없고
worktree에도 sealed `run-index.json`/per-scenario receipt/extraction bundle이
없다. 정적 271/439 registry와 10개 DB flow receipt는 439개 실제
full-stack 시나리오 실행을 대체하지 않는다.

### PDM-FINAL-R2-003 — 제품·설계·사업 계약 freeze 미완료 (P0)

현재 `implementation-evidence/design-screen-closure.yaml:3`,
`implementation-evidence/design-domain-closure.yaml:3`,
`specs/product/business-model-contract.yaml:5`가 모두 `REVIEW_REQUIRED`다.
핵심 여정과 비용·가치 판단을 독립 승인한 FINAL 계약이 없으므로 운영 책임과
기능 완결성을 release truth로 승격할 수 없다. 또한 현재
`specs/ui/screens/OPS-004.md`와 `packages/ui/src/screen-projection-ops.ts`에는
권위 ZIP에 없는 `business-health` addendum 흔적이 남아 있어, 상업 지표를
권위 화면에 섞지 않고 별도 승인된 closed operation으로 분리했는지 freeze
결정도 필요하다. 최신 `screen.ts`의 6-section 순서 자체는 권위 순서와 일치한다.

### PDM-FINAL-R2-004 — 인증 브라우저 증거가 synthetic/mock에 한정됨 (P1)

`cas-010-authenticated.json`/`cas-011-authenticated.json`은 authenticated
positive처럼 보이지만 `playwright.config.ts:31-46`이
`tests/e2e/support/mock-api.ts`를 29100번 control plane으로 기동하고 CAS
fixture provider를 사용한다. CAS-010도 runs/filters/suggestions/budget가
`PARTIAL`이다. 실제 PostgreSQL seed→Control API→Svelte SSR/DOM으로 값을 읽은
증거가 아니다. `cas-010.json`, `cas-011.json`, `ops-004.json`, `int-002.json`의
기본 trace는 모두 `BLOCKED`/error summary이고 OPS-004·INT-002의
authenticated populated trace가 없다. 사용자가 실제 상태·불확실성·근거·다음
행동을 즉시 파악한다는 핵심 PdM 목표를 판정할 수 없다.

### PDM-FINAL-R2-005 — AI/provider 및 source observation 운영 폐쇄가 없음 (P1)

현재 PDM-003 receipt의 `measured.providerTurns`와 `sourceDocuments`가 각각
`0`이고 parser-normalization row는 `NOT_APPLICABLE/NO_SOURCE_OBSERVATIONS`다.
`implementation-evidence/provider-runtime-closure.md`도 provider adapter
receipt, AgentRun/budget/provenance, typed API와 browser/UI approval closure를
remaining cross-surface gate로 남긴다. 승인→consent/opt-out→gateway
dispatch→callback/poll→immutable provider receipt→reconciliation→UI readback과
실제 source/parser observation을 입증하지 못하므로, AI 분석 및 외부 전달
운영 가능성을 LGTM할 수 없다.

## 확인된 positive evidence (blocking gate를 대체하지 않음)

- 현재 `apps/review-console/.../budgets/screen.ts`의 six-section 순서는 권위
  OPS-004 순서와 일치한다.
- 기존 Flow 01–10과 PDM-003은 동일한 이전 digest와 correlation ID를 기록하고
  PostgreSQL 18.4/SERIALIZABLE receipt 및 정상/negative branch를 포함한다.
- static validation 기록은 warnings/errors 0과 271 base/439 effective
  registry를 보여준다.
- CAS mapper에는 hypotheses, counter-evidence, unknowns, investigations,
  next-actions typed projection 코드가 있다.

## 재검토 조건

1. source 변경을 멈추고 최신 digest로 flow/CAS/PDM-003 evidence와
   MANIFEST/archive를 재생성해 checksum·tree/archive parity를 통과시킨다.
2. 권위에 없는 BusinessHealth addendum의 closed operation/화면 포함 여부를
   명시적으로 결정하고 design/domain/business closure를 독립 LGTM 후 FINAL로
   freeze한다.
3. 외부 evidence root에서 439 acceptance를 실행해 sealed run-index,
   per-scenario receipts, extraction receipt와 source/archive binding을 만든다.
4. production-shaped PostgreSQL seed로 OPS-004·INT-002·CAS-010·CAS-011의
   authenticated wide/medium/compact positive/unknown/stale traces를 저장한다.
5. provider/source runtime positive·negative receipt와 UI readback을 생성한
   뒤, 변경 없는 동일 digest로 PdM 재리뷰를 요청한다.
