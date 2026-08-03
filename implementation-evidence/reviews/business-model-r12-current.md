# Business-model independent review R12 — current source snapshot

검토일: 2026-07-20 UTC  
권위 ZIP: `gurine-codex-authority-pack-v13.0.0-20260712.zip`  
권위 ZIP SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

이 검토는 첨부된 v13 authority만 기준으로 현재 working tree를 다시 읽은
read-only business-model review다. `specs/product/business-model-contract.yaml`
및 owner/addendum 자료는 아직 `REVIEW_REQUIRED`인 구현 제안·검증 입력으로만
취급했으며 authority를 대체하지 않는다. 이 문서는 source를 수정하지 않았다.

## Verdict

```text
BUSINESS_VERDICT: CHANGES_REQUIRED
```

공개 공익 파일럿의 고객 가치(공개 사실·근거·정정·소명)와 후원/고객이
편집 우선순위를 살 수 없다는 원칙은 authority의 방향과 맞는다. 그러나 현재
비용/예산을 실제 사업 판단에 사용할 수 있는 원장 경로, 비용 export, AI 가치
관측, 그리고 evidence freeze가 닫히지 않았다. 따라서 획득·활성화·유지와
수익/비용/리스크의 전체 business LGTM을 발행할 수 없다.

## Review matrix

| 축 | 판정 | 현재 관찰 |
|---|---|---|
| 대상 고객·가치 전달 | Stage 1 범위 PASS | authority `docs/02-governance-and-revenue.md`와 `docs/27-product-strategy-and-principles.md`의 시민·기자·연구자 가치, 무료 public facts/evidence, editorial independence 원칙을 확인했다. |
| 획득·활성화·유지 | Stage 1 범위 PASS, 유료 주장 금지 | 무료 update subscription 경로는 공익 파일럿의 보조 유지 경로다. Stage 2 membership/API와 Stage 3 audit SaaS의 paid acquisition, activation, retention, CAC는 현재 출시 사실로 증명되지 않았다. |
| 수익·편집 독립성 | 조건부 PASS (fail-closed) | `public_funding.rs`의 서명 disclosure 부재 시 UNKNOWN 처리와 pay-to-remove/priority coupling 부재는 긍정적이다. 다만 최신 source/evidence parity가 닫히기 전에는 운영 리스크를 최종 승인할 수 없다. |
| OPS-004 비용·예산 | **BLOCKED (P0)** | authority가 요구하는 reservation→settlement, cap pause, override reason/expiry/approver, currency·freshness snapshot이 HTTP/UI에서 실제 원장으로 입증되지 않았다. |
| 비용 보고서 export | **BLOCKED (P0)** | 현재 export는 `ops.agent_runs` 합계와 bytes를 만들지만 reservation/settlement/provider usage/correction head 기반의 결정적 group-by 원장이 아니며, authority `BinaryDownload` wire contract가 bytes/checksum/rights를 보존하지 않는다. |
| AI 가치·비용 운영 | **BLOCKED (P1)** | CAS projection은 owner budget projection을 읽는 개선이 있으나 provider usage/settlement/reconciliation과 연결된 positive/negative business witness가 없다. PDM-003의 `providerTurns: 0`, `sourceDocuments: 0`은 실제 AI 가치 루프를 증명하지 않는다. |
| 증거/재현성 | **BLOCKED (P0)** | 현재 source provenance digest와 flow/PDM receipt digest가 다르고 MANIFEST checksum이 실패한다. 같은 snapshot의 authenticated PostgreSQL→Control API→Svelte 증거가 없다. |

## Blocking findings

### BM-R12-OPS004 — authority 예산 의미와 현재 projection이 서로 닫히지 않음 (P0)

authority `authority-v13/specs/ui/screens/OPS-004.md`의 여섯 section은 spend,
forecast, soft/hard/fallback limit, threshold alert, approver/reason을 즉시
답해야 하며, `getBudgetOverview`는 authority의 closed
`BudgetOverviewResponse`를 반환해야 한다. 현재
`services/control-api/src/service/query_business.rs`는
`ops.read_business_health_projection_v1()`를 `business_health_query()`에서
호출해 `BusinessHealthV1` addendum을 budget envelope로 사용한다
(현재 파일 SHA-256 `4a3c01c675a3e81261d0e7d0843198126e74c170ebb48afb8001957512595fa8`).
이 projection은 authority BudgetOverview와 다른 계약이며, 변경된 local
schema의 addendum 필드가 authority ZIP의 권위를 소급하지 않는다.

DB에는 `ops.budget_reservations`와
`ops.budget_reservation_ledger_entries` owner 경계가 존재하지만, OPS-004
응답이 이를 동일한 as-of/currency/freshness snapshot으로 읽었다는 witness가
없다. 관측 부재·혼합 통화·stale·reservation-only·settled·reconciliation
required·over-cap을 숫자 0/READY와 구분하고 다음 owner action을 제시하는
authenticated positive/negative trace가 필요하다.

**종료 조건**

1. authority `BudgetOverviewResponse`와 server/OpenAPI/generated client/UI의
   byte/JSON-schema를 일치시키고 addendum BusinessHealth를 별도 승인된
   operation으로 분리하거나 authority 경계 밖에서 제거한다.
2. reservation/settlement/reconciliation ledger, cap pause, override의
   reason·amount·expiry·approver를 한 snapshot에 결속한다. unknown/mixed/stale는
   nullable 값과 typed reason/owner action으로만 표현한다.
3. clean PostgreSQL 18.4에서 populated·empty·mixed-currency·stale·reservation-
   only·settled·over-cap 사례를 실행하고 compact/wide SSR readback을 저장한다.

### BM-R12-EXPORT — export가 재현 가능한 경제 원장 산출물이 아님 (P0)

현재 `cost_export_query()`는 `ops.agent_runs.actual_cost`와 `max_cost`를
기간 조건(`created_at >= from` 및 `<= to`)으로 합산한 뒤 CSV/JSON bytes와
content hash를 만든다. 이는 authority `docs/11-operations-and-cost.md`의
job reservation, provider usage settlement, correction head, exact half-open
window와 다르며 `groupBy`가 provider/model/case/day row를 실제로 materialize하지
않는다. `exportCostReport`의 authority 응답은 `BinaryDownload`인데 현재
generated type은 `id/status/version`만 선언해 bytes, media type, filename,
length, rights, revision, receipt를 호출자에게 보존하지 않는다.

**종료 조건**

1. immutable reservation/settlement/provider-usage/correction head에서 exact
   `[from,to)`·groupBy rows를 생성하고 empty/unknown/partial/mixed/corrected
   상태를 구분한다.
2. download 경계와 generated client에 binary bytes, media type, filename,
   byteLength, content checksum, rights/revision, export audit receipt를
   함께 bind한다. authority와 local schema 충돌은
   `implementation-evidence/spec-conflicts.md`에 결정하고 fail-closed로
   검증한다.

### BM-R12-AI — AI 비용·가치 루프가 사업 판단으로 증명되지 않음 (P1)

`query_analysis_vm.rs`(SHA-256
`7fa06aa0eff6fb5240546f3f86fb40b77b997aab58fe93733a6b5c3cf687aa5f`)와
`query_analysis_detail.rs`(SHA-256
`109c60fe1bf9fa01315e81030893fefdfeb3d0d5a412de78202b4deb55ae0b81`)는 typed
budget/output/provenance projection을 포함한다. 그러나 현재 runtime trace는
CAS-010/CAS-011 모든 section이 `BLOCKED`이고 `errorSummary: true`다. provider
receipt, reservation-only, settled, released, reconciliation-required,
over-cap/pause, human approval의 DB→Control API→Svelte readback이 없다.
`implementation-evidence/provider-runtime-closure.md`도 provider adapter
receipt generation, AgentRun start/transition, budget settlement, tool/source
provenance, typed API/UI approval을 remaining gate로 명시한다.

PDM-003 관측 창은 PostgreSQL 18.4라는 환경 정보와 fail-closed 상태를 보여주지만
`providerTurns: 0` 및 `sourceDocuments: 0`이므로 paid/value loop나 AI source
analysis가 발생했다는 증거가 아니다.

### BM-R12-EVIDENCE — source/evidence/archive freeze parity 실패 (P0)

현재 `python3 scripts/source_provenance.py --print`의 source tree digest는
`ff22ea8db2da4aa589b8020d4a1f9a7a8aa8ce36c2e192e98b170817f9a2de67`
(`source_file_count: 4339`, `git_head: ef2b63295f42dca37058e1d56712ab99e2c3e2b3`)
이다(이 review 파일을 추가하기 직전 측정한 snapshot이며, 최종 freeze 때 이
문서 자체를 포함해 digest를 다시 계산해야 한다). 반면 flow-01..10 및 PDM-003 receipts는 모두
`sourceTreeDigest: 8bae4389de93f5875b24815b12572e086a0d4b3607acd77b563454088a45c060`
를 가진다. `sha256sum --check MANIFEST.sha256`는 현재 tree에서 26개 mismatch로
실패하고, archive/clean extraction parity도 이 snapshot으로 닫히지 않았다.
이 receipt들은 현재 구현의 business 결과를 증명하는 근거로 사용할 수 없다.

`implementation-evidence/design-screen-closure.yaml`,
`implementation-evidence/design-domain-closure.yaml`,
`specs/product/business-model-contract.yaml`의 top-level status가 모두
`REVIEW_REQUIRED`이므로 business contract를 FINAL로 간주할 수도 없다.

**종료 조건**

1. 구현을 멈춘 단일 final source snapshot에서 MANIFEST/checksum/tree digest와
   source archive/clean extraction parity를 재생성한다.
2. 같은 digest/correlation으로 OPS-004, CAS-010/011, provider, flow/PDM
   receipt를 재생성하고 authenticated PostgreSQL→API→Svelte body/DOM readback을
   저장한다.
3. acceptance registry의 모든 hard gate를 실제 실행한 sealed evidence bundle과
   contract/design FINAL verdict를 함께 검증한다.

## Positive boundaries (not sufficient for LGTM)

- Stage 1 공개 정보와 기본 구독은 유료 우선순위·paywall과 분리되어야 하며,
  funding disclosure가 없을 때 UNKNOWN으로 남기는 현재 경계는 올바른 방향이다.
- authority 비용 정책은 모델 비용뿐 아니라 DB·storage·egress·legal/editorial·
  support 원가와 3개월 reserve를 포함하므로, 단순 `agent_runs` 합계로 매출성·
  margin·CAC를 주장해서는 안 된다.
- addendum business health/paid commercial acceptance는 authority v13의
  Stage 1 business approval이 아니며, 이를 근거로 `LGTM` 또는
  `ARTIFACT_READY`를 발행할 수 없다.

## Evidence digests

```text
authority-v13/docs/02-governance-and-revenue.md
d451521e12d246d1fd0808f13a44035f62baeff73831e0c6035365fbc47f7071
authority-v13/docs/11-operations-and-cost.md
c0a161f3bb0675f18dc2478bb22d86947282985f27cae284beae60fb75473c8b
authority-v13/specs/ui/screens/OPS-004.md
(authority tree pinned by ZIP SHA above)
services/control-api/src/service/query_business.rs
4a3c01c675a3e81261d0e7d0843198126e74c170ebb48afb8001957512595fa8
services/control-api/src/service/query_analysis_vm.rs
7fa06aa0eff6fb5240546f3f86fb40b77b997aab58fe93733a6b5c3cf687aa5f
services/control-api/src/service/query_analysis_detail.rs
109c60fe1bf9fa01315e81030893fefdfeb3d0d5a412de78202b4deb55ae0b81
implementation-evidence/runtime-traces/ops-004.json
5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2
implementation-evidence/runtime-traces/cas-010.json
03e2601a58ddae54f64aae1ac07c9ce2408f088113da5cdf3306ba325af3bbd9
implementation-evidence/runtime-traces/cas-011.json
7960b20f6808818001413381946f42df30f933d1d7cb8f874759e354a73f7a6d
implementation-evidence/provider-runtime-closure.md
cbc22b42ce5d9ea4b25b5207afb52096e0e286e9e76579b912a74279903adaa7
```
