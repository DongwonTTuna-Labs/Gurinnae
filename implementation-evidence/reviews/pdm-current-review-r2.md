# PdM 독립 fresh review R2 — 2026-07-20

검토 대상은 권위 ZIP SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`와
현재 worktree의 source/evidence뿐이다. 이전 Gurinnae 버전·별도 자료·이전
리뷰 verdict는 판정 근거로 사용하지 않았다. 소스 파일은 수정하지 않았고 이
문서만 작성했다.

현재 `scripts/generate_pdm_flow_evidence.py::source_digest()`를 실행해 얻은
source digest는 다음과 같다.

```text
SOURCE_TREE_DIGEST: 7e0b0c4f3f07ce59752d0a497ba89031915b9ceeed9ad302035a8b24b52148d1
CORRELATION_ID: 303922c4-ab36-433f-aa69-5157ea5a0d2f
```

## Verdict

```text
PDM_VERDICT: CHANGES_REQUIRED
```

## 확인된 진전 (blocking gate를 대체하지 않음)

- `flow-01`부터 `flow-10`과 `pdm-003-observability-20260719.json`이 모두
  위 source digest와 동일 correlation ID를 기록하고 `pass: true`다.
- Flow 03은 signal→triage→case→evidence→review→publication의 owner
  receipt/audit/outbox/readback과 stale negative를 포함한다.
- Flow 04/05/06은 response submission, correction/retraction, source drift
  mapping/backfill/checkpoint/dedupe의 정상·부정 branch를 포함한다.
- Flow 07/08/09/10은 rule evaluation/activation/rollback, step-up/SoD
  decision, subscription create→verify→management→update→unsubscribe,
  kill-switch activate→deactivate의 durable receipt를 포함한다.
- `CAS-011` projection은 persisted output에서 hypotheses,
  counter-evidence, unknowns, investigations, next-actions와 citations를
  typed view-model로 투영한다.
- OPS-004 screen manifest와 `query_business.rs`에 business-health projection
  및 `BusinessHealthPanel` 연결이 존재한다.
- authority snapshot과 `verification/static-validation.txt`의 현재 정적
  validator 결과는 `warnings: 0`, `errors: 0`, `RESULT: PASS`를 기록한다.

## Blocking findings

### PDM-R2-001 — MANIFEST가 현재 runtime evidence snapshot에 결속되지 않음 (P0)

현재 실행:

```text
sha256sum --check MANIFEST.sha256
```

결과는 11개 checksum mismatch이며 실패 파일은
`implementation-evidence/runtime-journey-receipts/flow-01-20260719.json`부터
`flow-10-20260719.json` 및 `pdm-003-observability-20260719.json`이다. 이 파일들은
현재 digest `7e0b0c4f...`를 기록하지만 MANIFEST는 그 재생성 전 세대의 bytes를
가리킨다. 따라서 현재 여정의 `pass: true` receipt를 최종 source/archive의
immutable outcome으로 검증할 수 없다.

필수 closure: source/evidence를 freeze한 뒤 MANIFEST.md와 MANIFEST.sha256를
마지막에 재생성하고 checksum, source archive clean extraction/member parity를
같은 snapshot에서 다시 통과시킨다.

### PDM-R2-002 — 제품·설계·비즈니스 release freeze가 닫히지 않음 (P0)

현재 다음 canonical 상태가 모두 release 승인 전 상태다.

- `implementation-evidence/design-screen-closure.yaml:3` — `status: REVIEW_REQUIRED`
- `implementation-evidence/design-domain-closure.yaml:3` — `status: REVIEW_REQUIRED`
- `specs/product/business-model-contract.yaml:5` — `status: REVIEW_REQUIRED`
- `implementation-evidence/business-model-metric-dictionary.md:3` —
  `Status: REVIEW_REQUIRED`; supplemental 41개 row가
  `implementation_status: MISSING`으로 명시됨

따라서 핵심 여정·정보위계·상업 qualification/activation/retention/revenue가
독립적으로 승인된 하나의 결정 완료 제품 계약이라고 판정할 수 없다. 존재하는
화면/DB projection과 43개 addendum probe(`business-model-20260719.json`)는
authority business-model LGTM을 대체하지 않는다. 41개 시나리오의 skip 없는
실행·typed persistence·운영 receipt와 독립 freeze verdict가 필요하다.

### PDM-R2-003 — 439 acceptance의 sealed external execution evidence 없음 (P0)

`Makefile`의 `run-acceptance-439`/`verify-execution-evidence`는
`ACCEPTANCE_EVIDENCE_ROOT`, run id, source commit/tree digest, archive,
extraction receipt와 checksum을 필수로 요구한다. 현재 worktree에는 해당
external evidence root의 sealed `run-index.json` 및 extraction receipt가
없고 `ACCEPTANCE_EVIDENCE_ROOT`도 설정되어 있지 않다. 따라서 439개 exact
acceptance scenario가 현재 archive와 동일 source snapshot에서 실제 실행됐다고
검증할 수 없다. 정적 registry·runtime journey receipt·addendum probe만으로
최종 PdM 운영 가능성을 닫을 수 없다.

필수 closure: 최종 frozen source/archive에 대해 439 acceptance를 실제 실행하고
run-index, per-scenario receipts, extraction receipt, source/archive digest
binding을 외부 evidence root에 sealed 저장한 뒤 두 verification gate를
통과시킨다.

### PDM-R2-004 — omnichannel provider 운영 closure가 아직 미완료 (P1)

`implementation-evidence/provider-runtime-closure.md`는 provider adapter
receipt generation, AgentRun/start-transition ownership, budget settlement,
tool/source-use provenance, typed API projection, browser/UI approval closure를
remaining cross-surface gates로 명시한다. 최신
`pdm-003-observability-20260719.json`도 `measured.providerTurns: 0`이다.
따라서 승인 UI→consent/opt-out→메일·SMS·Telegram·WhatsApp·LINE·KakaoTalk
dispatch→callback/poll→immutable provider receipt→reconciliation→UI
readback을 하나의 실제 synthetic provider-double 운영 영수증으로 확인할 수
없다. 사용자가 요청한 AI 분석·사람 승인·외부 메시지 실행 폐쇄 루프의 운영
가능성을 이 상태에서 LGTM할 수 없다.

필수 closure: 각 채널에 대해 provider config/secret revision binding,
정상·replay·ambiguous·opt-out·kill-switch branch, callback/poll, delivery
receipt/reconciliation 및 승인 후 UI readback을 DB owner/gateway/worker를
관통하는 source-bound receipt로 추가한다.

## 재검토 조건

1. source freeze 후 MANIFEST/checksum/archive parity를 clean PASS로 만든다.
2. design/domain/business contract를 독립 LGTM 후 `FINAL`로 freeze하고 41개
   supplemental scenario를 skip 없이 실행한다.
3. sealed external 439-acceptance evidence를 생성해
   `make verify-execution-evidence`와 `make verify-acceptance`를 통과시킨다.
4. provider/AI 승인·전송·reconciliation/UI readback closure를 추가한다.
5. 위 동일 frozen digest에 대해 독립 PdM fresh review를 재실행한다.

위 항목 중 하나라도 남아 있으므로 현재 판정은 `PDM_VERDICT:
CHANGES_REQUIRED`이며 `ARTIFACT_READY`를 발행할 수 없다.
