# PdM 독립 리뷰 — v13 current snapshot (2026-07-20)

## 검토 범위와 판정 기준

검토 기준은 첨부된 v13 authority ZIP SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`와 현재
`/home/dongwonttuna/Documents/Programming/Gurinnae` worktree의 소스 및
implementation-evidence뿐이다. 이전 Gurinnae 버전이나 별도 자료, 과거
review verdict를 현재 판정의 근거로 사용하지 않았다. 이 파일 외 소스·스키마·
fixture는 수정하지 않았다.

현재 소스 tree digest는 다음 명령으로 재계산했다.

```text
python3 - <<'PY'
import runpy
m = runpy.run_path('scripts/generate_pdm_flow_evidence.py', run_name='__review__')
print(m['source_digest']())
PY
=> 8bae4389de93f5875b24815b12572e086a0d4b3607acd77b563454088a45c060
```

## Verdict

```text
PDM_VERDICT: CHANGES_REQUIRED
```

현재 제품은 정적 계약과 일부 PostgreSQL journey probe가 존재하지만, 같은
release snapshot에 묶인 실행 증거·인증된 핵심 화면 readback·AI/source 운영
루프가 닫히지 않았다. 따라서 사용자가 각 동선에서 근거·현재 상태·불확실성·
다음 행동을 인지부하 없이 즉시 이해할 수 있고, 운영자가 그 동선을 반복해서
서비스할 수 있다는 PdM LGTM을 발행할 수 없다.

## Blocking findings

### PDM-R4-001 — source/evidence/MANIFEST/archive freeze 불일치 (P0)

현재 source digest는 `8bae4389…`이나 Flow 01–10 및
`pdm-003-observability-20260719.json`은 모두
`9ecdfa4c56c7fa04cb9808cef46b0b1bb2b2edbdfc521c3a6a453c419827a190`을
기록한다. `sha256sum --check MANIFEST.sha256`도 현재 worktree에서 다음
14개 이상 파일을 실패시킨다(0030 migration, Flow receipts, 분석/control
소스, agent fixtures, OpenAPI, e2e support, verification generated samples).
이 상태에서는 receipt의 PASS가 현재 제출 archive에서 재현 가능한 결과인지
판별할 수 없고, old receipt를 최신 코드의 근거로 승격할 수 없다.

**LGTM 조건:** 구현 변경을 멈춘 한 개의 final snapshot에서 source digest를
고정하고, 같은 digest로 Flow 01–10/PDM-003/CAS 및 모든 runtime receipt,
`MANIFEST.md`·`MANIFEST.sha256`, source archive와 clean-extraction parity를
재생성한다. checksum과 archive 내부/외부 digest가 모두 동일해야 한다.

### PDM-R4-002 — 439개 effective acceptance의 sealed 실행 증거 부재 (P0)

정적 registry는 `effective_scenarios: 439`, `effective_features: 40` 및
`skipped_count: 0`을 선언하고 static validation은 271 base scenario에
대해 PASS를 기록한다. 그러나 `Makefile`의 `run-acceptance-439`가 요구하는
`ACCEPTANCE_EVIDENCE_ROOT`, `ACCEPTANCE_RUN_ID`, source commit/tree digest,
archive, extraction receipt와 sidecar가 현재 환경에 설정되어 있지 않으며,
worktree에도 외부 evidence root의 `run-index.json`, 439 per-scenario
receipt, runtime-layer receipt, extraction bundle이 없다. 정적 registry,
PostgreSQL addendum probe(35/43/8 cases), 또는 기존 flow receipt는 full
acceptance를 대체하지 않는다.

**LGTM 조건:** 변경 없는 동일 snapshot을 외부 evidence root에서 정확한
selector로 한 번 실행하고 439개 각각의 non-skipped receipt와 모든 runtime
layer receipt를 sealed run-index에 묶는다. source commit/tree digest,
archive SHA-256, clean extraction receipt SHA-256가 상호 검증되고
`effective_acceptance.py --mode evidence`가 PASS해야 한다.

### PDM-R4-003 — 제품·화면·도메인·사업 계약이 FINAL이 아님 (P0)

현재 `implementation-evidence/design-screen-closure.yaml:3`,
`implementation-evidence/design-domain-closure.yaml:3`,
`specs/product/business-model-contract.yaml:5`가 모두 `REVIEW_REQUIRED`다.
따라서 94개 화면의 ten-second contract/상태·오류·행동, domain journey의
운영 책임, 그리고 qualification→data-ready→paid value의 사업 의사결정이
release truth로 승인되지 않았다. `specs/ui/screens/OPS-004.md`와
`packages/ui/src/screen-projection-ops.ts`에는 authority ZIP에 없는
`business-health` addendum 흔적도 남아 있어, authority 화면에 포함할지
별도의 승인된 closed operation으로 분리할지 freeze 결정이 없다.

**LGTM 조건:** 독립 PdM/디자이너/도메인/비즈니스 리뷰가 동일 design bundle을
검토하고 모든 top-level status를 `FINAL`로 고정한다. open decision/blocker는
없어야 하며, OPS-004 business-health 경계를 한 가지 계약과 화면·operation·
trace로 명시하고 effective registry에 반영해야 한다.

### PDM-R4-004 — 핵심 authenticated 사용자 여정이 mock/partial/block 상태
 (P1)

`playwright.config.ts`는 review-console과 public-web을
`tests/e2e/support/mock-api.ts`(127.0.0.1:29100)에 연결한다. 따라서
`cas-010-authenticated.json`의 runs/filters/suggestions/budget가 모두
`PARTIAL`이며, 이는 production-shaped PostgreSQL seed→Control API→Svelte
SSR/DOM readback이 아니다. 인증 positive처럼 보이는 `cas-011-authenticated`
도 하나의 synthetic populated row만 확인한다. 반대로 현재
`ops-004.json`와 `int-002.json`은 SSR 200이지만 모든 section이 `BLOCKED`이고
`errorSummary: true`이며, 기본 CAS-010/011 trace도 같은 상태다. 운영자가
상태, 근거, 불확실성, 다음 action을 즉시 읽고 승인할 수 있다는 핵심 목표를
이 증거로는 판정할 수 없다.

**LGTM 조건:** ephemeral PostgreSQL 18.4에 production-shaped seed를 넣고
실제 Identity→Control API actor assertion→SvelteKit SSR/DOM 경로로
OPS-004·INT-002·CAS-010·CAS-011의 wide/medium/compact 정상·unknown·stale
상태를 캡처한다. 값·근거 locator·revision·error recovery action이 typed
projection으로 readback되고, authenticated trace에 mock control-plane
의존성이 없어야 한다.

### PDM-R4-005 — AI/provider/source observation 운영 루프가 닫히지 않음 (P1)

`pdm-003-observability-20260719.json`에서 `measured.providerTurns: 0`,
`sourceDocuments: 0`이며 parser-normalization row는
`NOT_APPLICABLE / NO_SOURCE_OBSERVATIONS`다. `provider-runtime-closure.md`
또한 AgentRun/transition ownership, budget settlement, tool/source-use
provenance, typed Control/API projection, provider adapter receipt, browser/UI
approval closure를 remaining gate로 명시한다. 그러므로 승인→consent/opt-out
→allowlisted gateway→callback/poll→immutable provider receipt→reconciliation
→UI readback, 그리고 실제 source/parser observation을 운영 경로로 증명하지
못한다. 외부 메일·메신저 전송은 사람 승인·근거·재시도·terminal receipt가
확인되지 않은 상태에서 성공으로 보고할 수 없다.

**LGTM 조건:** 실제(또는 production-shaped, 명시된 synthetic adapter) source
document와 provider turn을 생성하고, parser/model/tool/source locator·cost/
budget·consent·opt-out·approval·callback/poll·reconciliation·terminal
receipt를 DB와 typed UI에서 동일 digest로 readback한다. 성공·실패·unknown·
kill-switch·재시도·중복 방지 branch를 포함하고 providerTurns/sourceDocuments가
0인 NOT_APPLICABLE 결과를 정상 운영 증거로 사용하지 않아야 한다.

## 확인된 positive evidence (blocking gate를 대체하지 않음)

- `verification/static-validation.json`은 authority ZIP hash와 함께 warnings 0,
  errors 0, 94 screens, 212 operations, 105 commands, 24 migrations,
  PostgreSQL 18.4, 439 effective registry를 구조적으로 확인한다.
- `journey-graph-20260719.json`은 PostgreSQL 18.4 SERIALIZABLE에서 J-01..J-12
  일부 journey start/handoff/ACK/replay/destination probe 35건을 PASS한다.
- `product-structure-20260719.json` 및 `business-model-20260719.json`은 각각
  addendum probe 8건과 43건의 durable receipt/audit/outbox/event 검사를 PASS한다.
- 현재 review-console budgets 화면의 section 순서는 `envelope → spend →
  forecast → limits → alerts → changes`로 authority OPS-004 순서와 맞는다.

위 항목은 정적·부분 runtime 신호이며, 위 P0/P1 blocker가 닫히기 전에는
제품 완결성 또는 ARTIFACT_READY의 근거가 아니다.

## 재검토 순서

1. 단일 final source snapshot을 freeze하고 위 digest mismatch를 해소한다.
2. MANIFEST·archive·clean extraction parity를 검증한다.
3. 외부 evidence root에서 439 acceptance를 실행·봉인한다.
4. design/domain/business 계약과 OPS-004 경계를 독립 LGTM 후 FINAL로 고정한다.
5. authenticated PostgreSQL→Control API→Svelte readback과 AI/provider/source
   receipt를 생성한다.
6. 모든 변경을 반영한 동일 digest로 PdM, 디자이너, 비즈니스, AI 및 나머지
   canonical role 재리뷰를 수행한다.

위 조건이 모두 충족되고 P0/P1이 0이며 독립 review가 동일 digest에 대해
LGTM일 때만 PdM 판정을 `LGTM`으로 변경한다.
