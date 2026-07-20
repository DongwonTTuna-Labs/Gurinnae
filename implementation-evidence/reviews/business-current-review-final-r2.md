# Business-model review — fresh re-review after OPS-004 query/export changes (2026-07-20)

기준은 첨부 v13 authority ZIP SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`뿐이다.
이번 검토는 `query_business.rs`의 최근 변경(UNKNOWN used와 export payload)을
현재 source에서 다시 읽고 authority OPS-004 schema/운영비/비용 export와
대조한 독립 re-review다. source는 수정하지 않았다.

## Verdict

`BUSINESS_VERDICT: CHANGES_REQUIRED`

최근 변경으로 비용 관측 부재·혼합 통화의 `dailyUsed`/`monthlyUsed`가 nullable로
바뀐 점과 export payload의 content hash/base64가 추가된 점은 긍정적이다. 하지만
실제 HTTP 응답에는 두 변경이 도달하지 않거나 사업 원장 의미를 충족하지 않는다.

## Findings

### BM-R2-OPS004 — UNKNOWN semantics가 아직 false-zero이고 reservation ledger와 분리됨 (P0)

현재 `services/control-api/src/service/query_business.rs`(digest
`901604248112b7dea97c793f4c9eb75384f188ddf55b90bb2ebfbec7e1b96afb`)는
`dailyUsed`/`monthlyUsed`만 혼합·무관측 시 `NULL`로 바꿨다. 그러나
`dailyLimit`/`monthlyLimit`은 budget row가 없을 때 여전히 문자열 `"0"`이고,
`dailySeries`/`topCases`는 빈 배열 또는 단일 통화 합계로 반환된다. summary status는
UNKNOWN이어도 운영자는 0 한도와 관측 불능을 동일한 숫자로 볼 수 있다.

쿼리는 여전히 `ops.budget_reservations`/`ops.budget_reservation_ledger_entries`
또는 `ops.read_agent_run_budget_projection_v1`를 읽지 않는다. authority
`docs/11-operations-and-cost.md`가 요구하는 reservation→settlement,
`PAUSED_POLICY`, override reason/amount/expiry/approver, reconciliation hold가
OPS-004 snapshot에 없다. `ops.read_business_health_projection_v1`와
qualification/revenue/margin/CAC metric도 이 authority operation의 closed
response에는 연결되지 않는다.

종료 조건: limit/used 모두 nullable + owner action/reason/freshness를 유지하고,
실제 reservation/settlement/reconciliation owner projection을 하나의 as-of/
currency snapshot으로 제공한다. no-observation, mixed-currency, stale,
reservation-only, settled, over-cap를 clean PostgreSQL 18.4에서 검증한다.

### BM-R2-EXPORT — binary payload가 materializer에서 제거되고 원장 기준도 아님 (P0)

`cost_export_query`는 이제 CSV/JSON bytes, `byteLength`, `contentSha256`,
`receiptSha256`, `contentBase64`, format/rowCount/period를 계산한다. 그러나
`services/control-api/src/service/query.rs`는 모든 결과에
`response_for(operation, &data)`를 적용하고, 현재 OpenAPI `BinaryDownload`
(`additionalProperties: false`, required `id/status/version`)가 이 필드들을
strip한다. generated client의 `BinaryDownload`도 id/status/version만 선언한다.
따라서 HTTP caller는 binary body·checksum·receipt를 받을 수 없고, UI export
action은 실질적으로 metadata-only이다.

또한 bytes가 immutable budget reservation/settlement/provider usage/correction
head가 아니라 `ops.agent_runs.actual_cost/max_cost` 단순합계에서 만들어진다.
`groupBy`는 query validation과 digest 입력에만 사용되어 provider/model/case/day
rows가 실제로 생성되지 않는다. 날짜 조건도 `<= to`로 닫혀 exact half-open
window 계약을 보장하지 않는다. authority screen-data contract의 required
`binary` 및 filename/media type/length/checksum/rights/revision dependency를
현재 response/schema/generated client가 충족하지 않는다.

종료 조건: authority conflict를 `spec-conflicts.md`에 결정하고, server-only
download 경계에서 deterministic binary + media type/filename/length/checksum/
rights/revision/audit receipt를 보존한다. reservation/settlement/provider usage
원장과 correction head 기반으로 각 groupBy row를 materialize하고 empty/unknown/
partial/mixed/corrected 케이스를 검증한다.

### BM-R2-EVIDENCE — fresh positive OPS-004 witness 없음 (P0)

`implementation-evidence/runtime-traces/ops-004.json`(digest
`5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2`)는
2026-07-19 trace이며 여섯 section이 모두 `BLOCKED`, `errorSummary=true`이고
source digest가 없다. 따라서 최근 source의 nullable UNKNOWN semantics와 export
payload가 DB→HTTP→SSR에 도달한다는 증거가 아니다. authenticated CAS-011 cost
READY와 CAS-010 PARTIAL trace도 OPS-004 export/ledger proof를 대체하지 않는다.

### Positive checks

- `cargo check -p gurine-control-api --locked` PASS (2026-07-20).
- `bun run --filter @gurine/ui test` PASS (38/38).
- OPS-004 화면 registry는 authority 6 sections로 유지된다.
- Stage 1 무료 funding/subscription 경계와 편집 독립성은 이전과 같이
  `public_funding.rs` 및 FLOW-09의 owner audit/outbox/readback으로 확인된다.

## Current digests

```text
services/control-api/src/service/query_business.rs
901604248112b7dea97c793f4c9eb75384f188ddf55b90bb2ebfbec7e1b96afb
services/control-api/src/service/response_materialize.rs
4526ccde20d1e5e9cadfc19378f20c3b276f017ab005e9c413d4ea51dbb777fd
packages/api-client-control/src/generated/types.gen.ts
(BinaryDownload remains id/status/version only)
apps/review-console/src/routes/internal/operations/budgets/screen.ts
943642530977e000cae12031e916d47010187a409bcda3bdbd07bf6b7fe22040
implementation-evidence/runtime-traces/ops-004.json
5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2
```

`BUSINESS_VERDICT: CHANGES_REQUIRED`
