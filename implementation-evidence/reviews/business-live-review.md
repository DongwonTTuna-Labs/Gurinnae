# Business-model live review — current source (2026-07-20)

검토자는 현재 working tree와 첨부된 v13 authority ZIP만 대조했다. authority ZIP
SHA-256은 `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`다.
이 문서는 구현을 수정하지 않은 독립 read-only 리뷰이며, 기존 review 문서의
판정을 승계하지 않고 현재 파일·HTTP trace·검증 결과를 다시 확인했다.

## Verdict

`BUSINESS_VERDICT: CHANGES_REQUIRED`

authority가 승인한 현재 사업 단계는 `docs/02-governance-and-revenue.md`의
Stage 1 public-benefit pilot이다. 시민·기자·연구자에게 공개 사실/근거/방법론,
정정·소명·기본 알림을 무료로 제공하고 후원자·고객·광고가 조사 우선순위나
공개 판단을 바꾸지 않아야 한다. 이 가치와 편집 독립성의 문서·공개 funding
surface는 대체로 맞지만, 실제 비용 통제와 운영자가 사업 판단을 내릴 수 있는
예산/AI 비용 경로가 닫히지 않았다. 따라서 대상 고객·가치만으로 전체 business
LGTM을 줄 수 없다.

## Review matrix

| 검토 축 | 판정 | 현재 증거 |
|---|---|---|
| 대상 고객·가치 전달 | Stage 1 범위 PASS | authority의 시민·기자·연구자·소명 담당자 JTBD와 공개 근거 우선 원칙이 `docs/27-product-strategy-and-principles.md`, public surface에 존재한다. |
| 획득·활성화·유지 | Stage 1 범위 PASS, 유료 주장 금지 | authority는 회원/데이터 상품/기관 SaaS를 Stage 2/3 로드맵으로 둔다. `PUB-029` 업데이트 구독은 무료 anonymous proof→verification 경로이며 유료 acquisition/retention 증거가 아니다. |
| 수익·편집 독립성 | 조건부 PASS | `services/public-api/src/service/public_funding.rs`는 서명된 disclosure가 없을 때 후원·비용·이해상충을 `UNKNOWN`으로 유지한다. `pub-023` trace는 여섯 section 모두 READY이고 pay-to-remove/priority coupling은 확인되지 않는다. |
| 비용·예산 운영 | **BLOCKED** | authority OPS-004의 spend/forecast/limit/alert/change 의미가 실제 response와 ledger에 닫히지 않았다(BM-OPS-004). |
| AI 비용·승인 경로 | **BLOCKED** | CAS-010/011은 문자열 비용만으로 reserved/settled를 투영하고 reservation/settlement receipt를 조회하지 않는다(BM-COST-001). |
| 현재 증거·재현성 | **BLOCKED** | OPS-004/CAS-010/CAS-011 trace가 모두 `errorSummary: true`, 전 section `BLOCKED`; MANIFEST checksum 25건 실패 및 journey source digest 세대 불일치가 있다(BM-EVIDENCE-001). |

## Blocking findings

### BM-OPS-004 — authority closed contract와 실제 예산 의미 불일치 (P0)

authority `OPS-004`는 `BudgetOverviewResponse`의 `data`에
`summary/providers/dailySeries/topCases/updatedAt`만 허용한다
(`authority-v13/specs/api/resource-schemas.yaml`, `additionalProperties: false`).
화면은 별도로 forecast의 confidence/assumption, soft/hard/fallback limit,
threshold alert, approver/reason을 즉시 답해야 한다.

현재 `services/control-api/src/service/query_business.rs:9-74`는 authority
`BudgetOverview`에 없는 `limits`, `forecast`, `alerts`, `changes`를 SQL JSON에
추가한다. `response_materialize.rs:80-109`는 authority schema의 알려진
property만 복사하므로 이 네 의미가 실제 HTTP response에서 제거된다. 그 결과
`packages/ui/src/view-models/ops-004.ts`와 specialized projection이 기대하는
forecast/limit/alert/change 값은 runtime에서 사용할 수 없다.

더구나 query는 budget limit와 비용 이벤트가 하나씩만 있어도 forecast를
`READY`/`MEDIUM`으로 만들고 고정 문구를 넣는다(`query_business.rs:62-67`).
이는 계산 window·freshness·실제 forecast receipt를 증명하지 않는다. `changes`는
`updated_by`를 곧바로 `approver`로 복사하고 audit reason이 없으면
`BUDGET_LIMIT_UPDATE`를 삽입한다(`:74`). 혼합 통화 시 daily/top-case가
`max(currency)`를 사용해 금액을 계속 노출하며, 원장 부재의 nullable 금액은
materializer의 `string_default`로 `0`/`KRW`로 변환될 수 있다. 비용이 UNKNOWN인
상태를 정상 잔액 또는 승인된 변경으로 오인하게 만드는 경로다.

**종료 조건**

1. authority closed response를 그대로 반환하고, 추가 business 의미가 필요하면
   authority가 승인한 별도 계약/operation으로 분리한다.
2. 실제 reservation/settlement/forecast/limit/alert/approver/reason fact와
   currency·window·freshness를 같은 snapshot으로 조회한다. 누락·혼합·stale은
   숫자나 `READY`가 아니라 typed `UNKNOWN/BLOCKED`와 owner action으로 보낸다.
3. clean PostgreSQL에서 populated, empty, mixed-currency, stale/reconciliation
   케이스를 실행하고 response/schema/generated client/UI/SSR trace parity를
   source digest와 함께 보존한다.

### BM-COST-001 — AI 비용이 원장·승인 가능한 경제 사실에 결속되지 않음 (P0)

`services/control-api/src/service/query_analysis_vm.rs:61-82`의 `cost_micros`는
소수점 뒤 여섯 자리만 취하고 추가 문자를 거부하지 않으며 음수도 허용한다.
CAS-010은 각 `agent_runs.max_cost`/`actual_cost` 문자열을 합산해
`AVAILABLE`을 만들고 `limit - settled`를 `reservedMicrosKrw`로 기록한다
(`:273-305`). 이는 예약 ledger가 아니며 malformed/missing run을 합계에서
조용히 제외한다. CAS-011도 `actualCost`가 파싱되면 provider receipt,
reservation, settlement/reconciliation 없이 `SETTLED`를 생성한다
(`query_analysis_detail.rs:150-191`).

이 상태에서는 새 Agent 실행을 승인하거나 kill-switch를 해제할 때 비용이
실제로 예약·정산됐는지, 한도를 넘었는지, reconciliation이 필요한지 판단할 수
없다. 특히 비용을 `0` 또는 남은 예산으로 보이는 값으로 축약하면 실제 비용·수익
정합성을 검증할 수 없다.

**종료 조건**

1. canonical numeric parser가 전체 문자열·부호·overflow·통화를 검증하고
   malformed/negative/missing을 보존한다.
2. CAS-010/011의 limit/reserved/settled/remaining은 실제 reservation,
   settlement, provider usage/cost receipt와 reconciliation digest가 있을 때만
   계산한다. 숫자 0은 물리적인 zero fact일 때만 허용한다.
3. missing, malformed, reservation-only, settled, reconciliation-required,
   over-cap fixture를 clean PostgreSQL에서 실행해 상태·reason·중단 다음 행동을
   browser projection으로 확인한다.

### BM-EVIDENCE-001 — 현재 business 운영 경로의 fresh positive witness 부재 (P0)

`implementation-evidence/runtime-traces/ops-004.json` (sha256
`5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2`),
`cas-010.json` (`03e2601a58ddae54f64aae1ac07c9ce2408f088113da5cdf3306ba325af3bbd9`),
`cas-011.json`
(`7960b20f6808818001413381946f42df30f933d1d7cb8f874759e354a73f7a6d`)은 모두 SSR 200이지만 각 section이 `BLOCKED`이고
`errorSummary: true`다. 이는 안전한 fail-closed 관찰 한 건일 뿐, 정상 비용 원장,
승인된 forecast, positive authenticated CAS render를 증명하지 않는다.

또한 `sha256sum --check MANIFEST.sha256`가 현재 tree에서 25개 파일을 실패하고,
여정 영수증은 flow 01–07에서 sourceTreeDigest
`27300c584021ee4b5b4d27562490d50c2e5d630259f2e5c01c409b779a88e5cf`, flow
08–10/PDM에서 `65621dbb71edf24ebd2edcde8e4b301a9fec2cdb0dd18d506b76a9a09bb53674`
를 사용한다. 서로 다른 source snapshot의 receipt를 현재 business 결과의
증거로 합칠 수 없다. `business-model-20260719.json`의 43 PASS는 문서 스스로
authority-v13 monetization approval이 아닌 implementation addendum이라고
명시한다.

**종료 조건**

1. 최종 source freeze 후 MANIFEST를 재생성하고 checksum·authority tree digest를
   PASS시킨다.
2. 모든 business/AI/여정 receipt를 동일한 최종 source digest로 재생성한다.
3. authenticated positive OPS-004/CAS-010/CAS-011 trace와 위의 negative/unknown
   케이스를 함께 저장하고, HTTP body가 authority schema와 일치함을 검증한다.

## Non-blocking/positive observations

- `PUB-023`의 funding projection은 값이 없는 상태를 `UNKNOWN`으로 유지해
  투명성·편집 독립성 원칙에 부합한다. 다만 이 trace의 source digest parity는
  global manifest closure 이후 다시 확인해야 한다.
- `PUB-029` 무료 구독은 공개 정보 접근을 paywall로 만들지 않는 authority Stage 1
  가치 경로와 정합하다.
- branch의 BusinessHealth/paid-commercial/action-approval addendum과
  `implementation-evidence/business-model-metric-dictionary.md`는 authority가
  아니며, 이를 이용해 Stage 2/3 매출·retention·margin·CAC를 이미 달성했다고
  주장하면 안 된다. 해당 기능을 배포하려면 별도 권위 계약과 완전한 billing,
  rights, isolation, receipt 증거가 필요하다.

## Evidence digests

```text
authority-v13/docs/02-governance-and-revenue.md
d451521e12d246d1fd0808f13a44035f62baeff73831e0c6035365fbc47f7071
authority-v13/specs/ui/screens/OPS-004.md
c740da8ffcb7255b9c39fd9bbcbcab5ca45f336a3c734294e0799eabeb880be3
authority-v13/specs/api/resource-schemas.yaml
8cfa0a1d436623525f75a81bdac7751f66855d0538150d83e79536c0ecfee16
services/control-api/src/service/query_business.rs
2f82f03637100c1ea8ecd8307dbb759340bff829a044564fd33731f699939deb
services/control-api/src/service/query_analysis_vm.rs
e8240941f79d8cd058d8a7078b76ad1493538520436b35b8b2b92b04baf7bb54
services/control-api/src/service/query_analysis_detail.rs
cdb26ffb270ecb7ba47cd9280c86f47635c2b1bc989d3201c5b4d4c11737351b
services/control-api/src/service/response_materialize.rs
4526ccde20d1e5e9cadfc19378f20c3b276f017ab005e9c413d4ea51dbb777fd
packages/ui/src/view-models/ops-004.ts
7de4ab4e20cc33fc3467e8eb5b1e112d99688c7e7b74cea8209e15958d194947
implementation-evidence/runtime-traces/pub-023.json
5ed2a3103567e055f8f1f2dccb6d5723de6ff751089f86a58c995f4f22b7b9ff
```

`...` 또는 축약 digest는 검증용 값이 아니다.
