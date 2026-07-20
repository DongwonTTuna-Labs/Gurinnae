# PdM 독립 freeze review R15 — current worktree audit

검토 시각: 2026-07-20 UTC (현재 worktree snapshot)
권위 ZIP SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
검토 HEAD: `5a3431b02c2132fe24276a6ed21db28dc69db099`
검토 시점 source-tree digest (`scripts/generate_pdm_flow_evidence.py`의
현재 규칙): `bb95e4205c6f8ca1b8a83a068cf0fa4212c80cc63c149134e55eedd46a951628`

이 문서는 구현을 수정하지 않은 독립 PdM 검토다. 권위 ZIP과 현재 source,
현재 runtime evidence만 대조했으며 이전 review 문서는 판정 근거로 사용하지
않았다. worktree에는 동시 작업과 미커밋 변경이 있으므로 위 digest는 이
검토 시점의 관측 snapshot이다.

## 판정

```text
PDM_VERDICT: CHANGES_REQUIRED
```

`LGTM_NO_BLOCKING`을 발행할 수 없다. 기능 구현의 상당 부분과 개별 flow의
정상/negative receipt는 보이지만, 현재 source/archive를 증명하는 freeze와
사용자 여정의 운영·데이터 증거가 아직 닫히지 않았다.

## P0 blockers

### PDM-R15-001 — source/evidence/manifest parity가 깨져 있음

현재 `sha256sum --check MANIFEST.sha256`는 **22 computed checksums did NOT
match**로 실패했다. 실패 파일에는 현재 수정된 migration, Control query 및
analysis projection, OpenAPI/spec, CAS visual snapshot과 테스트가 포함된다.
동일 시점의 live source digest는 위 `bb95…`이지만 runtime receipt는 서로 다른
세대다.

- Flow 01–07: correlation
  `9148df41-554e-4645-b0fe-9f82822a1c35`, digest
  `27300c584021ee4b5b4d27562490d50c2e5d630259f2e5c01c409b779a88e5cf`
- Flow 08–10 및 PDM-003: correlation
  `b772c0c6-1c24-4c85-b090-60fa85f60b7d`, digest
  `65621dbb71edf24ebd2edcde8e4b301a9fec2cdb0dd18d506b76a9a09bb53674`

각 JSON의 `pass: true`는 그 JSON이 현재 source/archive의 durable outcome임을
증명하지 못한다. 최종 source 변경을 멈춘 뒤 하나의 digest로 모든 flow와
PDM-003을 재생성하고, MANIFEST를 가장 마지막에 생성한 후 checksum·tree
digest·archive clean extraction/member parity를 다시 확인해야 한다.

### PDM-R15-002 — 설계/product freeze가 final 상태가 아님

현재 `DESIGN.md`의 상태가 `REVIEW_REQUIRED`이고
`implementation-evidence/design-domain-closure.yaml` 및
`implementation-evidence/design-screen-closure.yaml`의 top-level 상태도
`REVIEW_REQUIRED`다. authority의 one-shot complete product와 repository의
design-freeze contract는 구현 승인 snapshot에서 이 상태를 `FINAL`로 요구한다.
핵심 여정·화면 정보위계가 독립 승인되지 않은 상태에서는 PdM 기능 완결성을
release truth로 승격할 수 없다.

### PDM-R15-003 — 439 acceptance 실행/추출 evidence가 없음

현재 `ACCEPTANCE_EVIDENCE_ROOT`, `ACCEPTANCE_RUN_ID`,
`ACCEPTANCE_SOURCE_COMMIT`, `ACCEPTANCE_SOURCE_TREE_SHA256`,
`ACCEPTANCE_ARCHIVE`, `ACCEPTANCE_EXTRACTION_RECEIPT` 및 sidecar가 설정되지
않았고, worktree에 `run-index.json`/sealed extraction receipt bundle이 없다.
`Makefile`의 `run-acceptance-439`/`verify-execution-evidence` 계약은 이
외부 evidence root와 source/archive 바인딩을 필수로 한다. 정적 registry,
개별 flow receipt, 단일 route probe만으로 271 base + supplemental 시나리오의
실제 full-stack 실행을 주장할 수 없다.

## P1 기능·운영 blockers

### PDM-R15-004 — CAS-010/011 data-backed 여정 증거가 없다

현재 `implementation-evidence/runtime-traces/cas-010.json`과
`cas-011.json`은 2026-07-19의 `ssrStatus: 200`이지만 모든 section이
`projectionState: BLOCKED`, `errorSummary: true`인 unauthenticated trace다.
이 trace는 권한 실패 상태가 올바르게 보인다는 것만 증명하며, 실제 DB의
분석 결과에서 사용자가 목적·현재 상태·불확실성·근거·다음 행동을 즉시 읽고
CAS-010 시각화의 문장/표 대안과 CAS-011 provenance graph 행을 확인하는
여정을 증명하지 않는다.

현재 typed mapper와 UI projection unit tests는 15개 PASS이고 서버/컴포넌트
연결 코드도 존재한다. 그러나 data-backed authenticated browser trace가 없고
기존 trace는 최신 source digest에 결속되지 않았다. 동일 source snapshot의
실제 PostgreSQL seed → Control API → Svelte SSR/DOM을 wide·medium·compact로
재실행해 시각화 값·narrative/table alternative·provenance row를 확인해야
한다.

### PDM-R15-005 — AI 결과 projection이 사용자 판단에 필요한 필드를 버림

현재 `services/control-api/src/service/query_analysis_detail.rs`의
`build_output`는 `answerFirstSummary`만 row에서 읽고
`hypotheses`, `counterEvidence`, `unknowns`, `investigationsPerformed`,
`nextActions`를 항상 빈 배열로 생성한다(대략 68–81행). analysis-worker와
authority schema에는 이 필드들이 실제 typed output으로 존재한다. 따라서
분석 결과가 저장돼도 운영자가 “무엇이 있었는가 / 무엇이 의심되는가 / 어떻게
찾았는가 / 다음에 무엇을 할 것인가”를 CAS-011에서 바로 알 수 없다. 원본
output·tool/source-use/citation/unknown/next-action을 상태별로 보존해
projection하고, 데이터가 없을 때만 명시적인 UNKNOWN reason을 표시해야 한다.

### PDM-R15-006 — 승인 큐의 필터·페이지가 실제 작업 목록을 재현하지 않음

`services/control-api/src/service/query_addendum_queue.rs`는 DB에서
`SELECT ops.read_action_queue_v1()`를 호출하지만 `actionKind`,
`proposalState`, `assignmentState`, `dueBefore`, `cursor`, `limit`를 DB
query에 전달하지 않는다. `appliedFilters`는 일부 문자열만 echo하고
`nextCursor`·`totalApproximate`는 항상 `null`이다. DB 함수는 assignment/risk/
quorum 값을 읽도록 보강돼 있으나, 운영자가 “지금 무엇을 왜 승인해야 하는가”를
정확히 좁혀 재현하고 다음 페이지를 이어가는 operation contract는 아직
충족되지 않는다. 실제 owner projection 기반 filtering·cursor/limit·empty/
invalid negative readback을 추가해야 한다.

### PDM-R15-007 — omnichannel provider의 end-to-end 운영 receipt가 없음

`implementation-evidence/runtime-journey-receipts/pdm-003-observability-20260719.json`
의 관측값은 `providerTurns: 0`이다. 현재 `provider-runtime-closure.md`도
provider adapter receipt generation을 “remaining cross-surface gates”로
명시한다. 코드에 adapter/callback/poll 경로가 존재하는 것과 별개로,
승인된 rendering → consent/opt-out → provider config/secret revision →
gateway dispatch/poll/callback → immutable provider receipt → reconciliation
및 UI readback을 실제 worker/PostgreSQL 경계에서 증명하는 clean synthetic
provider-double receipt가 없다. 이 증거 없이 메일·SMS·Telegram·WhatsApp·LINE·
KakaoTalk 운영 가능성을 LGTM할 수 없다.

## 확인된 positive checks (blocking gate를 대체하지 않음)

- authority-v13 first-read 문서와 SHA-256을 대조했다.
- `bun run check`: 세 SvelteKit 앱과 UI 모두 0 errors/0 warnings.
- CAS projection/mapper targeted tests: 15 pass, 0 fail.
- 저장된 Flow 01–10 JSON은 개별 `pass: true`이며 Flow 03/04/05/06/07/08/09/10
  에 named owner operation/receipt가 기록돼 있다. 단, 위 parity 문제 때문에
  현재 source의 증거로 승격하지 않았다.

## 재검토 조건

1. source 변경을 freeze하고 한 번의 clean PostgreSQL 18.4 실행으로 Flow
   01–10/PDM-003 및 data-backed CAS trace를 생성한다.
2. `DESIGN.md`와 두 design closure top-level 상태를 독립 designer/PdM
   승인 후 `FINAL`로 고정한다.
3. `MANIFEST.md`/`MANIFEST.sha256`를 마지막에 재생성하고
   `sha256sum --check`, `authority_tree_digest.py`, archive clean extraction
   및 member/content parity를 통과시킨다.
4. 외부 acceptance evidence root에서 439 시나리오를 실행하고
   `make verify-execution-evidence`/`make verify-acceptance`를 통과시킨다.
5. AI output projection, approval queue filtering/pagination, omnichannel
   provider receipt/reconciliation을 source→DB→API→Svelte까지 검증한 뒤,
   변경 없는 동일 digest로 PdM 독립 재리뷰를 요청한다.

