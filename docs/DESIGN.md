# Gurinnae v13 제품·디자인 축

이 문서는 v13 권위 팩의 화면·여정·운영 계약을 구현하고 리뷰할 때 사용하는
단일 판단 축이다. 새로운 제품 규칙을 추가하지 않으며 충돌 시 권위 팩 원문이
우선한다.

## 고정된 리뷰 대상

- 권위 팩 SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
- 구현 대상: Public 34 + Response 8 + Internal 52 = 94 screens. 권위 UI
  `screen-catalog.yaml`/`screen-build-manifest.yaml`에서 계산한 UI 집합은
  496 authored sections와 720 state occurrences이며, UI operation/action은
  ref와 unique를 구분해 보존한다(각각 data-operation refs 226/unique 203,
  action refs 250/unique 196). 전체 제품 계약의 212 external operations,
  105 commands, 5 read-only agents와 9 typed tools는 UI 집합과 별도로
  검증한다. 현재 branch addendum가 제시하는 129 journey edges와 11
  delivery milestones는 authority ZIP의 canonical artifact가 확인되기
  전까지 비권위 제안으로 취급한다.
- 구현 tree의 effective registry가 497 sections처럼 더 큰 수를 산출하면
  그것은 addendum delta로 별도 보고한다. authority set equality의 기대값을
  맞추기 위해 source-derived count를 숨기거나 덮어쓰지 않는다.
- 동일성은 최종 `MANIFEST.sha256` 및 `scripts/authority_tree_digest.py` 결과로
  고정한다. dirty tree, 이전 버전 문서, fixture-only 결과는 리뷰 대상에서
  제외한다.

### 전송 계약의 생성물 정합성

화면에서 제출하는 `decideJourneyHandoff`는 생성된 OpenAPI와 TypeScript
클라이언트가 동일한 권위 wire shape를 사용해야 한다. `schemaVersion`은
`decide-journey-handoff.request.v1` const 문자열이고, `decision`은
`ACKNOWLEDGE|DECLINE`, `reasonCode`는 ACK의 `null`을 포함한 다음 9개 closed
enum이어야 한다: `CAPABILITY_UNAVAILABLE`, `OBJECT_SCOPE_MISMATCH`,
`CONFLICT_OF_INTEREST`, `WORKLOAD_CAPACITY`, `DEPENDENCY_BLOCKED`,
`SUBJECT_INVALID`, `OWNER_UNAVAILABLE`, `POLICY_BLOCKED`,
`RECEIVER_DECLINED`. 이 shape는
`scripts/generate_addendum_openapi.py`에서 결정적으로 생성하고
`bun run scripts/generate-clients.ts --check`와 source/generated
semantic-equality 검증으로 고정한다. UI BFF override만으로는 계약 정합성을
충족한 것으로 보지 않는다.

### 권위 집합과 addendum witness의 분리

리뷰 evidence에는 다음 두 집합을 같은 표나 count로 합산하지 않는다.

| 집합 | 기준 | 기대값 | 판정 |
| --- | --- | ---: | --- |
| Authority UI | `screen-catalog.yaml` + `screen-build-manifest.yaml` | 94 screens / 496 sections / 720 state occurrences | `set-equality`가 아니면 실패 |
| Effective implementation | source-derived registry | 현재 구현에서 계산한 값 | authority와 다른 delta를 숨기지 않고 기록 |
| Addendum journey | `journey_graph_addendum`·`journey_handoff_addendum` | 129 edges / 11 delivery milestones | authority에 매핑된 row만 closure 대상, 나머지는 `NON_AUTHORITY_PROPOSAL` |
| Addendum business | BusinessHealth·PaidEvidencePacket | 13 qualification predicates, strict paid MVW, 29–56일 retention | canonical source가 확인될 때만 상업 gate에 포함 |

`497/840`처럼 effective registry에서만 관찰되는 section/state 수는
`implementation-evidence/design-screen-closure.yaml`에
`authority_count`, `effective_count`, `delta_ids`, `delta_reason`,
`source_digest`를 함께 남긴다. 이를 authority count로 대체하거나 성공 근거로
세지 않는다. 각 row는 화면·section/state ID를 직접 열거하며 단순 sentinel이나
빈 observation 파일은 witness가 아니다.

화면별 closure row는 다음을 모두 포함한다.

```text
screen_id
route
typed_view_model
authored_section_ids (ordered)
action_ids (ordered)
state_occurrence_ids (ordered)
required_regions_by_archetype
authority_source_path
authority_source_sha256
implementation_source_digest
runtime_trace_path
```

`component_variant`와 `section_order`는 실제 렌더 경로에서 읽혀야 하며,
generic `OperationData`/raw JSON fallback은 closure row를 만들 수 없다.

## 사용자 목표와 화면 순서

모든 동선에서 사용자는 현재 상태, 가장 중요한 근거, 다음 행동을 한 화면에서
인지해야 한다. 화면은 설명을 읽어야만 해석되는 대시보드가 아니라 근거가 있는
결론과 다음 행동으로 자연스럽게 이어지는 작업 공간이어야 한다.

각 화면은 authored section 순서를 우선하며 다음 여섯 의미 슬롯을 화면별
계약에 맞춰 매핑한다(모든 화면에 동일한 순서를 강제하지 않는다). 이 여섯
슬롯은 authority에 없는 새 필드·상태를 추가하는 규칙이 아니라 인지부하를
검토하기 위한 annotation heuristic이다.

`object`(무엇인지) → `state`(현재 상태) → `answer`(확인된 답) →
`unknown`(모르는 것과 이유) → `evidence`(출처·시점·버전) →
`next_action`(지금 할 수 있는 한 가지 행동).

94개 화면은 모두 화면별 typed view-model과 section/action 계약을 가져야 한다.
generic `OperationData`, raw JSON 그대로의 렌더링, 필드명 추측형 renderer,
공통 문구로 의미를 대체하는 구현은 허용하지 않는다. 권위 copy는 임의로
재작성하지 않고 verbatim으로 표시한다.

기본 위계는 다음과 같다.

1. 현재 상태와 신뢰도(성공·부분 성공·대기·차단·오류·오프라인)
2. 사용자가 지금 결정해야 하는 핵심 정보와 근거
3. 다음 행동 하나와 예상 결과
4. 세부 근거·이력·불확실성·복구 방법

데이터가 없거나 오래된 경우 0, 빈 문자열, 임의의 성공 문구로 채우지 않는다.
`UNKNOWN`/`NOT_APPLICABLE`와 그 이유, 담당자, 재검토 시점을 표시한다.

## 상호작용·접근성

- 모든 입력 오류는 해당 입력과 `aria-invalid`, `aria-describedby`, 복구 초점을
  함께 제공한다.
- 제출·승인·외부 전송은 서버가 발급한 최신 대상/버전/다이제스트에 묶고,
  결과 receipt와 다음 상태를 즉시 보여준다.
- 키보드 순서, 200% 확대, 작은 화면의 표→카드 변환에서도 정보 관계와 주 행동을
  보존한다.
- 오프라인·재인증·충돌·부분 실패는 초안 보존과 재시도/취소 경로를 제공한다.
- WCAG 2.2 AA를 기준으로 320/768/1024/1440/1920px와 200% 확대를 검증한다.
  DOM 읽기 순서와 포커스 이동은 키보드·스크린리더에서 동일해야 하며 상태
  변경은 live region으로 알린다.

## 여정·수익·AI 폐쇄 루프

- authority에 대응하는 canonical source path와 digest가 확인된 여정만
  edge의 branch/handoff/terminal을 컴파일하고,
  `action → PostgreSQL transition → immutable receipt → audit/outbox →
  destination`을 각 edge에서 증명한다. 129개 addendum edge는
  `edge_id`, `from`, `to`, `branch_selector`, `terminal_kind`, `handoff_kind`,
  `reconciliation_receipt_id`를 실제 row에서 읽어야 하며, 존재하지 않는 edge를
  임의의 성공 observation으로 채우지 않는다. J-12는
  `QUALIFICATION_PENDING → QUALIFIED → DATA_READY`의 각 predicate와
  receipt를 남기고, J-11은 다음 다섯 milestone을 각각 승인·실행·전송·receipt·
  reconciliation으로 닫는다: `PREPARE`, `APPROVAL`, `DISPATCH`,
  `DELIVERY`, `RECONCILIATION`.
- 상업 루프(addendum 제안, authority에 없는 경우 `NON_AUTHORITY_PROPOSAL`)는
  isolated SKU와 무료/유료 경계를 먼저 고정하고, 다음 13개 qualification
  predicate를 모두 typed row와 receipt로 증명한다: `IDENTITY_VERIFIED`,
  `ORG_SCOPE_BOUND`, `CASE_DATA_READY`, `EVIDENCE_LINEAGE_READY`,
  `RIGHTS_READY`, `CONSENT_READY`, `OWNER_ASSIGNED`, `SLA_BOUND`,
  `ACTIVATION_EVENT_RECORDED`, `VALUE_EVENT_RECORDED`, `PAID_MVW_ELIGIBLE`,
  `INVOICE_RECONCILED`, `SUPPORT_PATH_READY`.
  strict paid MVW는 무료 기능의 단순 플래그가 아니라 isolated SKU·active org·
  29–56일 retention window·`PaidEvidencePacket`(근거 ID, metric snapshot,
  invoice/receipt, purchaser/tenant binding)와 묶인다. CAC payback은 실제 3개월
  기여이익과 비용·수익 원장을 사용하며 근거가 없으면 `UNKNOWN`으로 fail-closed한다.
- AI 루프(addendum 제안, authority에 없는 경우 `NON_AUTHORITY_PROPOSAL`)는
  `raw artifact → parser/OCR/ASR → snapshot/lineage → typed tool
  call → provider receipt → agent output schema → citation → human approval →
  separate execution → channel receipt/reconciliation` 순서다. 각 node는
  `node_id`, `schema_version`, `input_digest`, `output_digest`, `rights_digest`,
  `receipt_id`를 갖고, edge는 parent digest·run/version fence·idempotency key를
  검증한다. 이메일·SMS·Telegram·WhatsApp·LINE·KakaoTalk 등 채널은 명시적
  consent/opt-out, destination allowlist, delivery receipt와 reconciliation이
  있어야 하며 승인 전 외부 실행이나 자동 범죄 단정은 금지한다. WAV/WebM처럼
  parser가 권위 상태에서 `BLOCKED`인 입력은 `NOT_ACTIVATED`를 성공으로
  변환하지 않고 reason·재검토 경로를 표시한다.

## 구현·리뷰 체크

리뷰어는 각 화면과 여정에 대해 다음을 실제 runtime 증거로 확인한다.

- 권위 screen/section/component/action과 typed view-model이 일치하는가
- action이 PostgreSQL domain row, immutable receipt, audit/outbox/event, 목적지 상태로
  이어지는가
- 근거의 출처·시점·불확실성·권한이 손실되지 않는가
- 오류·복구·반응형·접근성 상태가 같은 화면 계약으로 검증되는가
- acquisition→activation→retention→revenue/cost 경로와 AI 분석→승인→메시지 전송
  경로가 실제 데이터와 reconciliation을 남기는가

이 체크리스트를 통과하지 못한 기능은 구현 완료나 LGTM으로 표시하지 않는다.

## 정량적 closure와 재현성

리뷰는 인상이나 화면 수만으로 통과시키지 않는다. 최종 source tree에서 다음
집합을 계산해 authority 집합과 정확히 비교한다.

- 94개 route의 typed view-model, authored section, action, 상태 프로필과
  authority UI 집합(496 sections, 720 state occurrences)의 set equality
- 구현 addendum edge/milestone가 authority에 매핑된 경우에만 branch selector·
  terminal 분류·handoff 목적지·reconciliation receipt를 검증한다
- 구현 addendum의 BusinessHealth metric/funnel·PaidEvidencePacket은
  authority에 canonical source가 존재할 때에만 closure 대상이 된다. 그 전에는
  `NON_AUTHORITY_PROPOSAL`로 기록하고 LGTM 조건으로 세지 않는다
- Agent의 raw artifact부터 citation·human approval·채널 receipt까지의
  lineage node/edge와 provider/tool/output-validation 영수증

리뷰 evidence의 최소 AI witness는 agent별 V2 output schema ID/digest,
`ToolCallV2` request·response schema, PostgreSQL tool adapter 결과,
`agent_output_validations` row, citation source-use FK, proposal persistence
row, human approval receipt, separate execution receipt, channel delivery
receipt를 모두 포함한다. `runtime_probe()` 값이나 in-memory snapshot만 있는
경로는 운영 closure가 아니다.

집합이 비어 있거나 generic fallback으로 채워진 경우에도 성공으로 간주하지
않는다. 정량 집합은 다음 canonical 입력과 명령으로 계산한다.

- 입력: `specs/ui/screen-catalog.yaml`, `specs/ui/screen-build-manifest.yaml`,
  `specs/ui/page-archetypes.yaml`, `specs/ui/screen-data-contracts.yaml`
- 실행: `PYTHON=python3 PYTHONDONTWRITEBYTECODE=1 python3 -B
  scripts/generate_effective_registry.py` 후
  `PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/validation/design_freeze.py
  --mode lint`. 생성된 registry/evidence의 output path와 `PASS` 결과를
  실행 기록에 고정한다.
- 증거: `implementation-evidence/design-screen-closure.yaml`,
  `implementation-evidence/design-domain-closure.yaml`와 생성된 effective
  registry JSON. 각 파일에는 source path, enumerated IDs, count, canonical
  set hash가 들어가야 한다.

`screen-build-manifest.states`의 720 occurrence와
`page-archetypes.state_profiles`의 richer semantic states는 서로 다른 집합이며,
screen ID와 state ID를 통한 mapping witness를 남긴다. 10 archetype의
required regions는 `NOT_APPLICABLE`로 생략할 때 이유·대체 region·복구 경로를
screen contract에 명시한다. viewport 검증은 320×568, 360×800, 390×844,
768×1024, 1024×768, 1280×800, 1440×900, 1920×1080 및 200%/400% 확대,
dynamic text·forced-colors를 포함한다(`docs/46-screen-composition-standard.md`,
`docs/37-accessibility-inclusive-design.md`,
`docs/38-responsive-and-device-strategy.md`).

각 검증은 같은 commit의 source
digest, 권위 ZIP SHA-256, 실행 시각, 도구 버전, PostgreSQL schema/catalog
digest를 함께 기록하고, 리뷰어는 digest가 바뀐 뒤의 이전 LGTM을 재사용하지
않는다. 동일한 입력을 두 번 실행할 때 projection·export·receipt payload가
byte-identical이어야 하며, 다른 idempotency payload·오래된 version/digest·
권한 없는 actor는 부작용 없이 명시적 실패 영수증을 남겨야 한다.

## 인지부하·운영 가능성 gate

각 화면의 첫 viewport와 compact 상태에서 다음 여섯 슬롯이 authored
section order를 보존하며 모두 접근 가능해야 한다.
`object`, `state`, `answer`, `unknown`, `evidence`, `next_action`.
GUIDED_FORM의 progress→questions→statement→consent→save, AUTH_SYSTEM의
situation→impact→next_actions→security_support→draft_state처럼 archetype별
예외는 권위 `screen-build-manifest.section_order`를 그대로 따른다.
주 행동은 하나만 강조하고 담당자·예상 결과·복구 경로를 바로 표시한다.
오류·stale·partial·offline·reauth·conflict는 마지막으로 확인한 근거와
초안을 보존하며, live region과 입력별 오류 연결을 통해 사용자가 원인을
추측하지 않도록 한다. 200% 확대, 키보드 전용, forced-colors 및 320px 폭에서
이 순서와 주 행동이 사라지면 디자이너 LGTM이 아니다.

## PdM 완료 판정 계약

각 사용자 행동은 다음 증거 묶음을 하나의 원자적 전이로 남겨야 한다.

`prepare/claim → domain write → immutable receipt → audit event → outbox/event →
destination projection → exact idempotent replay`.

분기 edge는 `edge_id`만으로 목적지를 추정하지 않는다. 서버가 저장한 branch
selector와 결과 코드를 검증하고, 허용된 branch contract의 목적지·terminal
분류·handoff kind를 선택한 뒤에만 receipt를 발행한다. 알 수 없는 branch,
오래된 version/digest, 다른 journey의 edge, 중복 key의 다른 payload는 모두
명시적 오류 영수증으로 종료한다.

결정·취소·재시도는 화면의 성공 문구만으로 닫히지 않는다. 같은 idempotency
key를 재전송하면 저장된 응답 본문과 receipt digest를 byte-for-byte 재생하고,
취소는 `CANCEL_REQUESTED`와 최종 reconciliation을 거친다. `DECLINE`은
replacement handoff와 복귀 목적지를 실제 row와 receipt로 남긴다. 이 증거가
없는 여정·business transition·AI 실행은 운영 가능으로 간주하지 않는다.
