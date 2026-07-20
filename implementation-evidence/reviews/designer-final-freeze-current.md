# Designer Independent Freeze Review — current source

DESIGN_VERDICT: CHANGES_REQUIRED

ROLE: PRODUCT_DESIGN / INFORMATION_ARCHITECTURE / ACCESSIBILITY_RESPONSIVE
REVIEWED_AT_UTC: 2026-07-20
AUTHORITY_ZIP_SHA256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

## Review boundary

이 리뷰는 위 authority ZIP과 그 안의 정보구조·화면 구성·접근성·반응형·상태
오류 UX 계약만 사용했다. 현재 worktree의 source와 실행 결과를 읽기 전용으로
대조했으며, 소스 코드는 수정하지 않았다. 관찰 시점의
`scripts/generate_pdm_flow_evidence.py::source_digest()` 값은
`6e510241695df53f3f3ee0ba6af2cbd196ac7bab63bcc29fb79fad8e724609a4`이다.
동시 작업이 계속되므로 이 digest가 바뀌면 본 verdict는 자동으로 stale이다.

## 실행한 검증

- `bun run --filter @gurine/review-console check`: 0 errors / 0 warnings
- `bun run --filter @gurine/review-console test`: 4/4 PASS
- `bun run --filter @gurine/review-console build`: PASS
- `bunx playwright test tests/e2e/visual-routes.spec.ts --grep 'CAS-010|CAS-011'`: 6/6 PASS
- `bunx playwright test tests/e2e/screen-runtime-traces.spec.ts --grep 'authenticated CAS'`: 1/1 PASS
  (CAS-010 API envelope → typed projection → visualization/table, CAS-011
  API envelope → typed projection → provenance/table assertions)
- `bunx playwright test tests/e2e/acceptance/accessibility-responsive.spec.ts --grep ACCESSIBILITY_RESPONSIVE`: 8/8 PASS
- `git diff --check`: PASS

위 결과는 현재 source로 새로 빌드한 실행에서 확인했으며, CAS positive test는
이전 R4에서 누락됐던 mock API authority envelope를 실제로 거친다. 따라서
CAS 매퍼 자체와 대표 DOM 렌더 경로에 대한 이전의 즉시 실패 원인은 관찰된
범위에서 해소됐다.

## Blocking findings

### D-FREEZE-001 — MANIFEST와 runtime receipt가 현재 source를 증명하지 못함 (P0)

`sha256sum --check MANIFEST.sha256`가 22개 파일에서 실패했다. UI와 CAS에
직접 관련된 실패 예시는 다음과 같다.

- `apps/review-console/src/lib/server/screen-load.ts`
- `packages/ui/src/screen-projection-specialized.ts`
- `packages/ui/src/screen-projection.test.ts`
- `packages/ui/src/view-models/ops-004.ts`
- `tests/e2e/screen-runtime-traces.spec.ts`
- `tests/e2e/support/mock-api-reads.ts`
- CAS-010/CAS-011 compact/medium/wide snapshots

또한 기존 flow receipt의 `sourceTreeDigest`는 flow 01–07에서
`27300c584021ee4b5b4d27562490d50c2e5d630259f2e5c01c409b779a88e5cf`, flow
08–10 및 PDM receipt에서 `65621dbb71edf24ebd2edcde8e4b301a9fec2cdb0dd18d506b76a9a09bb53674`로
기록돼 현재 digest와 다르다. `runtime-traces/cas-010.json`과
`cas-011.json`도 인증되지 않은 `BLOCKED` 관찰만 남아 있고, 새 positive
CAS test는 성공했지만 source digest가 포함된 영속 runtime witness로 저장되지
않는다.

필수 조치: 최종 소스 변경을 멈춘 뒤 MANIFEST/sidecar, 94개 route/state
trace와 CAS positive visualization/provenance receipt를 같은 source digest로
재생성하고, checksum·clean extraction·archive parity를 재검증해야 한다.
그 전에는 화면의 시각·접근성 LGTM을 release freeze에 사용할 수 없다.

### D-FREEZE-002 — projection 부재 시 raw DTO 추측 fallback이 소스에 남음 (P1)

`packages/ui/src/components/sections/AuthorityRecordSection.svelte`의
`semanticRecords(runtime)`, `visibleEntries(record)`, `valueFor(field)` 경로는
projection이 falsy일 때 `runtime.data`를 순회하고 필드명을 정규화해 값을
추측한다. 이는 authority의 screen-specific typed VM, fail-closed UNKNOWN,
generic/raw JSON fallback 금지 계약과 모순된다. 현재 `ScreenPage`가 대부분의
실행에서 projection을 전달하더라도, 이 경로가 컴포넌트 계약에 존재하는 것
자체가 누락/legacy fixture 상태에서 raw DTO 노출의 side door다.

필수 조치: fallback을 제거하고 projection이 없거나 section envelope가
불완전하면 이유·범위·복구 안내가 있는 UNKNOWN/BLOCKED만 렌더한다. raw DTO를
넣은 회귀 테스트로 94개 화면에 DTO 필드가 표시되지 않는지 검증해야 한다.

### D-FREEZE-003 — 미확인 상태가 내부 operation path를 사용자 문구로 노출함 (P1)

`packages/ui/src/components/OperationData.svelte`의 `unknownFields`가
`field.source`를 그대로 출력한다. `projectFetchedData()`가 만드는 source는
`operationId.path`(예: `getResponseDraft.$.status`) 형식이므로, 값이 없거나
stale일 때 사용자는 담당자·범위·재검토 시점 대신 내부 API 계약 문자열을
읽게 된다. 이는 authority의 unknown/empty/freshness copy와
`docs/DESIGN.md`의 implementation path 비노출·인지부하 축소 요구를 충족하지
못한다.

필수 조치: source path를 화면별 허용 provenance label·scope·owner·next
review/retry 정보로 매핑하는 typed field metadata를 만들고, raw operation ID는
브라우저 텍스트에서 제거한다. unknown/partial/stale 상태별로 이 metadata와
복구 action이 존재하는지 94-screen/state matrix에서 확인해야 한다.

### D-FREEZE-004 — 화면 projection 안에 raw JSON/Record 요약 경로가 남음 (P1)

`packages/ui/src/screen-projection-specialized.ts`는 OPS-004의
`alert_details`를 `JSON.stringify(vm.alerts)`로 만들고, CAS-010/CAS-011의
`summarize()`는 임의 `Record<string, unknown>`의 key/value를 잘라서 화면에
보낸다. 이는 authority가 요구하는 도메인별 typed field·상태·단위·복구 문구를
보장하지 않으며, provider/DB 키 이름이 사용자에게 노출되거나 중요한 배열
항목이 잘릴 수 있다. `OperationData`가 projection만 소비한다는 사실은 이
projection 자체가 raw JSON인 문제를 해결하지 않는다.

필수 조치: alert, agent identity/output/model/cost를 각각 closed discriminated
view-model로 변환하고 필요한 label·unit·unknown reason만 명시적으로
투영한다. `JSON.stringify`, 임의 key enumeration, `Record<string, unknown>`
직접 표시를 제거하고 malformed/empty 입력은 UNKNOWN/BLOCKED로 남기는
positive/negative projection test를 추가해야 한다.

### D-FREEZE-005 — navigation action이 raw runtime.data에서 목적지를 추측함 (P0)

`packages/ui/src/local-actions.ts`의 `dataTarget()`와 `collectUrls()`는
`runtime.data` 전체를 재귀 순회해 `href`, `runId`, `caseId` 같은 키 이름과
action 문자열을 조합하여 링크를 만든다. `ScreenActions.svelte`는 이 함수를
`open-run`, `open-evidence` 등 핵심 navigation에 사용한다. 즉 API DTO가
projection allowlist와 별도로 변경되거나 악성/오래된 URL을 포함하면 화면이
서버가 승인한 목적지·권한·version/digest 없이 이동할 수 있다. CAS-010의
`open-run`도 현재 typed `runs` projection에 행별 destination이 없어서 이 raw
추측 경로에 의존한다.

필수 조치: 각 navigation action에 서버가 준비한 typed destination
(`href`, target id, expected version/digest, allowed state)을 action-specific
envelope로 제공하고, `local-actions.ts`의 DTO key scan/fallback route 생성을
제거한다. destination이 없으면 UNKNOWN/blocked copy와 복구 경로만 보이며,
다른 case/run으로의 IDOR·stale destination negative test를 추가해야 한다.

### D-FREEZE-006 — CAS-010 실행 행의 목적·모델·상태·비용이 count로 축약됨 (P1)

`specializedFields()`의 CAS-010 `runs` section은 `vm.runs.length`만
`실행 목록`/`실행 건수`로 투영한다. `AgentAnalysisProjection.svelte`도 해당
행의 purpose, model, status, cost, source count와 typed `href`를 렌더하지
않고 metric table만 표시한다. authority `CAS-010.md`가 요구하는
“목적·입력·비용·상태·채택 결과”와 “purpose·model·status·cost”가 첫 화면에서
사라져, 사용자가 어떤 실행을 열지 비교하거나 다음 행동을 선택할 수 없다.

필수 조치: `Cas010RunRow` discriminated VM을 만들고 실행별 목적·입력
evidence 수·model/version·상태/실패 reason·비용/통화·proposal counts·서버
승인 destination을 record-list/table로 렌더한다. 각 행의 link는
D-FREEZE-005의 typed destination binding을 사용하고 compact에서도 label과
상태가 보존되는지 검증해야 한다.

### D-FREEZE-007 — CAS-011 입력·citation·사람 결정이 count/요약으로 소실됨 (P1)

CAS-011의 `inputs`는 `vm.inputs.length`, `citations`는
`vm.citations.length`, `decisions`는 `vm.decisions.length`만 표시한다.
`identity`, `model`, `output`, `safety`도 `summarize()`의 첫 네 key만 한 줄로
축약한다. authority가 요구하는 입력 evidence ID/hash, policy/model version,
structured output validation, citation source/locator/revision, accepted/
rejected 상태와 reason을 사람이 하나씩 검토하거나 채택할 수 없다. 현재
provenance graph가 한 행 이상 보이는 것은 graph 관계의 대안일 뿐, 원
인용·결정 목록의 완전한 대체가 아니다.

필수 조치: input/citation/decision별 typed rows와 상태·locator·revision·hash·
reason·destination을 렌더하고, protected/stale/hash-mismatch/unknown을
행별로 표시한다. `accept-suggestion`/`reject-suggestion`는 선택된 row의
ID/version/digest와 영수증을 연결해야 하며, count-only projection으로는
화면 closure를 통과시키지 않는다.

## Non-blocking positive observations

- 공통 화면 projection은 94-screen registry에서 allowlist envelope를 만들고,
  CAS-010/CAS-011은 typed metric table과 provenance table을 별도 렌더러로
  연결한다.
- CAS visual 3 viewport × 2 screen, authenticated API/projection/render,
  접근성 8개 acceptance가 현재 빌드에서 통과했다.
- `OperationData`는 현재 projection fields만 표시하며 알 수 없는 필드는
  별도 상태로 보인다. 다만 D-FREEZE-002의 legacy caller side door 때문에
  이 장점만으로 generic fallback 금지 계약을 닫을 수 없다.

## Verdict

현재 UI 구현의 대표 CAS·접근성 동작은 개선됐지만 source/evidence/manifest가
동일한 freeze 세대가 아니며 raw fallback·내부 path 노출·raw JSON projection·
raw navigation 추측·CAS 실행 행/상세 목록 축약도 남아 있다. 위 blocker를
root 수정하고 동일 source digest로 evidence를 재생성한 뒤 독립 재리뷰가
필요하다.

```text
DESIGN_VERDICT: CHANGES_REQUIRED
```
