# PdM 독립 구현 리뷰 — current worktree audit

검토 시각: 2026-07-20 UTC  
권위 ZIP SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`  
검토 HEAD: `5a3431b02c2132fe24276a6ed21db28dc69db099`  
검토 당시 source digest (`scripts/generate_pdm_flow_evidence.py` 규칙):
`73174ddfdfa5ca82aac603449e6b402209d8b9ef567a5a0463339d4c222e34b7`

이 문서는 구현을 수정하지 않은 독립 PdM 검토다. worktree에 동시 변경이
많으므로 위 digest에 포함되지 않은 이후 변경은 이 판정의 근거가 아니다.

## 판정

```text
PDM_VERDICT: CHANGES_REQUIRED
```

핵심 공개·응답·정정·스키마 드리프트·규칙·승인·구독·kill-switch 여정의
기존 PostgreSQL receipt 구조는 정상/negative branch를 표현하고 있으며,
현재 코드에도 typed CAS 시각화와 provider poll 경로가 존재한다. 하지만
현재 source/archive를 증명하는 evidence freeze가 없고, 승인 큐와 AI 결과
표면이 실제 운영자의 질문에 답하도록 완결됐다는 증거가 없어 LGTM을 발행할
수 없다.

## P0 blockers

### PDM-SUB-000 — canonical product/design freeze가 FINAL이 아님

`DESIGN.md`는 현재 `Status: REVIEW_REQUIRED`이고
`implementation-evidence/design-domain-closure.yaml`와
`design-screen-closure.yaml`의 top-level status도 `REVIEW_REQUIRED`다.
`design-freeze-contract.md`는 release freeze에서 이 값들이 정확히 `FINAL`이어야
하며, `REVIEW_REQUIRED`를 구현 승인으로 간주하지 못하게 한다. 따라서 화면·도메인
계약의 독립 LGTM과 구현 source의 동시 snapshot이 닫히기 전에는 PdM의 여정
완결성도 release truth로 승격할 수 없다. 설계 bundle을 최종화하고 design
freeze lint/freeze를 실행해 동일 digest의 독립 review를 남겨야 한다.

### PDM-SUB-001 — source/evidence/manifest freeze parity 실패

- `sha256sum --check MANIFEST.sha256`가 **36 computed checksums did NOT match**로
  실패했다. 실패 대상에는 현재 변경된 migration, control fixture, generated
  OpenAPI/client와 runtime journey receipt가 포함된다.
- `scripts/authority_tree_digest.py`도 첫 manifest mismatch
  (`apps/review-console/src/lib/view-models/cas-010.ts`)에서 중단된다.
- receipt는 하나의 현재 snapshot이 아니다. `flow-01..07`은 correlation
  `9148df41-554e-4645-b0fe-9f82822a1c35`, digest `27300c...`; `flow-08..10`과
  `pdm-003`은 correlation `b772c0c6-1c24-4c85-b090-60fa85f60b7d`, digest
  `65621d...`이고, 현재 live digest는 `73174d...`다.

따라서 각 JSON의 `pass: true`는 현재 source tree의 durable outcome을
증명하지 않는다. 최종 source 변경을 멈추고 flow 01–10/PDM-003을 한 번의
clean PostgreSQL 18.4 실행으로 재생성한 뒤 MANIFEST를 마지막으로 생성해야
한다. archive clean extraction/member parity도 같은 digest로 재검증해야 한다.

### PDM-SUB-002 — 439 acceptance 실행 증거 부재

`Makefile`의 `run-acceptance-439`는
`ACCEPTANCE_EVIDENCE_ROOT`, run id, source commit/tree digest, archive 및
extraction receipt를 모두 요구한다. 현재 환경에는 `ACCEPTANCE_EVIDENCE_ROOT`
가 설정되어 있지 않고, `run-index.json`/extraction receipt를 포함한 외부
execution bundle도 없다. 따라서 271 base 시나리오와 supplemental 시나리오가
실제 stack에서 실행됐다는 source/archive-bound receipt를 확인할 수 없다.
정적 registry, route snapshot, 단일 journey probe는 이 gate를 대신할 수 없다.

## P1 functional/operability blockers

### PDM-SUB-003 — 승인 큐가 운영자가 신뢰할 수 있는 작업 목록이 아님

현재 `services/control-api/src/service/query_addendum_queue.rs`는
`addendum_queue_query`에 query parameters를 받지 않고(`:1-4`),
`ops.read_action_queue_v1()`의 전체 결과를 그대로 읽는다(`:5-18`).
응답의 `appliedFilters`는 항상 빈 배열/`UPDATED_DESC`, cursor와
`totalApproximate`는 항상 null(`:20-29`)이다. authority operation contract는
`actionKind`, `proposalState`, `assignmentState`, `dueBefore`, `cursor`,
`limit`, `sort`를 지원하고(`specs/product/addendum-operation-contracts.yaml:142-160`),
운영자가 “무엇을 왜 지금 승인해야 하는가”를 바로 찾아야 한다.

또한 `normalize_action_queue_items`가 실제 row 값 대신 `assignment: null`,
`riskClass: "MEDIUM"`, 고정 `requiredSlots/satisfiedSlots/blockingSlots`
를 만든다(`query_addendum_queue.rs:137-178`). 담당자, 위험도, quorum, 기한이
실제 persisted facts와 다르면 승인자는 잘못된 대상을 승인할 수 있고, 화면의
정보 부하를 줄이는 대신 오해를 만든다. DB owner projection에서 typed
assignment/risk/quorum/freshness를 읽고, 증거가 없는 필드는 READY가 아니라
필드별 UNKNOWN/BLOCKED reason으로 표시하며, 필터·cursor·limit의 실제
readback/negative test를 추가해야 한다.

### PDM-SUB-004 — AI 분석 결과가 사용자 질문(무엇/의심/검색 경로/다음 행동)을 잃음

`services/control-api/src/service/query_analysis_detail.rs:68-86`의
`build_output`는 persisted run output에서 `answerFirstSummary`만 읽고
`hypotheses`, `counterEvidence`, `unknowns`, `investigationsPerformed`,
`nextActions`를 항상 빈 배열로 만든다. `build_model`도 tool call 수를 항상
0으로 반환한다(`:47-55`). 실제 analysis-worker가 생산한 인터넷/멀티모달
도구 사용, 의심 가설, 반대 근거, 검색한 범위, 다음 실행이 CAS-011 화면과
승인 대상에 도달하지 않으므로 사용자가 “무엇이 있었고, 무엇이 의심되며,
어떻게 확인했고, 앞으로 무엇을 할지”를 한눈에 판단할 수 없다.

각 status branch(SUCCEEDED/FAILED/RECONCILIATION_REQUIRED)에 대해 저장된
typed output·coverage·tool/source-use/citation·unknown·next-action을 그대로
projection하고, 빈 배열이 정당한 경우 검색 범위와 완료/미완료 receipt를
함께 표시해야 한다. CAS-010/011의 visualization/provenance digest와
browser/DB receipt를 같은 source digest로 재생성해 확인해야 한다.

### PDM-SUB-005 — omnichannel 운영 경로의 clean provider evidence 부재

현재 코드에는 Telegram/WhatsApp/LINE/SMS/Kakao typed adapter, callback,
SMS/Kakao authenticated poll 및 queue/claim owner가 있다. 그러나
`implementation-evidence/provider-runtime-closure.md`는 provider adapter
receipt generation을 별도 미완료 cross-surface gate로 남기고 있으며, 현재
journey receipts에는 승인된 rendering → provider config/preflight/secret
revision → 실제 dispatch/poll/callback → immutable receipt → reconciliation/
opt-out → UI readback을 한 번에 증명하는 clean PostgreSQL/worker/gateway
receipt가 없다. 코드 경로의 존재만으로 메일·메신저 알림의 운영 가능성을
LGTM할 수 없다.

현재 `pdm-003-observability-20260719.json`도 `providerTurns: 0`인 clean
PostgreSQL 관측 창이다. 해당 행의 `pass: true`는 provider turn이 없어도
허용하는 관측식일 뿐, provider receipt가 생성됐다는 뜻이 아니다.

각 판매/활성 채널에 대해 synthetic provider double을 사용하더라도 실제
gateway 경계와 DB owner를 통과하는 정상·replay·ambiguous·kill-switch·opt-out
receipt를 추가하고, provider secret revision binding과 source/archive digest를
검증해야 한다.

## 재검토 조건

1. source 변경을 freeze하고 MANIFEST/checksum/tree digest/archive parity를
   clean PASS로 만든다.
2. 동일 source digest의 flow 01–10/PDM-003과 439 acceptance external bundle을
   생성해 `make verify-execution-evidence`와 `make verify-acceptance`를
   통과시킨다.
3. 승인 큐의 typed filter/assignment/risk/quorum/freshness와 AI output/coverage/
   next-action을 owner DB→API→Svelte 화면까지 연결하고 각각 실제 receipt와
   negative branch를 남긴다.
4. omnichannel provider receipt/reconciliation/opt-out 증거를 추가한 뒤,
   변경 없는 동일 digest로 PdM 재리뷰를 요청한다.

검토 시점에는 위 항목 중 하나라도 열려 있으므로 최종 `LGTM_NO_BLOCKING` 및
`ARTIFACT_READY`를 반환할 수 없다.
