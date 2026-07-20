# AI/runtime 독립 리뷰 — current tree (2026-07-20)

권위 입력은 `gurine-codex-authority-pack-v13.0.0-20260712.zip` 하나만 사용했다
(`sha256: 960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`).
리뷰어는 구현 파일을 수정하지 않았고, 이 문서만 증거 산출물로 추가했다.

## Verdict

```text
AI_VERDICT: CHANGES_REQUIRED
```

현재 트리는 AI/runtime hard gate와 동결 게이트를 닫지 못한다. 따라서
`AI_VERDICT: LGTM_NO_BLOCKING` 또는 `VERDICT: ARTIFACT_READY`를 발행할 수 없다.

## Blocking findings

### AI-RUNTIME-FINAL-001 — source/evidence freeze가 여전히 깨져 있음 (P0)

현재 실행한 `sha256sum --check MANIFEST.sha256`는 다음 11개 파일에서 실패했다.

- `apps/review-console/src/routes/internal/operations/budgets/screen.ts`
- `packages/ui/src/components/sections/ExecutionReceiptPanel.svelte`
- `packages/ui/src/screen-projection-ops.ts`
- `specs/api/submission-api.openapi.json`
- `implementation-evidence/runtime-journey-receipts/flow-01`, `flow-02`, `flow-03`, `flow-08`, `flow-09`, `flow-10`, `pdm-003-observability` (20260719)

`python3 -B scripts/authority_tree_digest.py`도
`apps/review-console/src/routes/internal/operations/budgets/screen.ts`의
manifest mismatch에서 중단했다. 따라서 현재 source와 runtime receipt/manifest가
하나의 digest로 묶였다는 증거가 없으며, 이 상태의 archive나 리뷰는 최종본의
증거가 될 수 없다.

필수 조치: 구현·증거 생성을 멈추고 단일 source digest를 고정한 뒤 journey/CAS
receipt, `MANIFEST.md`, `MANIFEST.sha256`, authority tree digest와 archive를
같은 snapshot에서 재생성하고 clean-extraction member parity를 다시 확인해야 한다.

### AI-RUNTIME-FINAL-002 — FETCH_URL rights가 실제 asset decision에 바인딩되지 않고 합성됨 (P0)

`services/analysis-worker/src/analysis_source_fetch.rs:76-90`은
`ops.assert_research_fetch_rights_v1(source_id, request_kind)` 결과만 받아
gateway를 호출한다. 이 결과의 `dimensions`은
`db/migrations/0030_v13_submission_session_hardening.sql:2250-2278`에서
`accessRight/privateStorageRight/modelEgressRight/modelUseRight`를 무조건
`ALLOW`로 만들고 나머지를 `UNKNOWN`으로 만든다. 이는 URL에서 실제로 생성되는
`asset_id`, revision, content hash에 대한 owner-approved rights row가 아니다.

이어 `ops.record_research_fetch_v1` (같은 migration 2315 이후)는 그 capability
UUID를 `raw.asset_rights_decisions.id`로 재사용하고, reviewer/license/evidence와
rights digest를 새 row에 채워 넣는다. 즉, 정확한
`(asset_id, asset_revision, asset_sha256, decision_version, decision_sha256)`를
검증된 기존 decision FK로 전달하지 않고 fetch 시점에 rights를 만들어낸다.
`effective_at`, license evidence, dimensions도 기존 asset decision의 사실이
아니며 모델 egress/use가 허용되지 않은 콘텐츠가 `UNKNOWN`/합성 `ALLOW` 경로로
ResearchArtifact가 될 수 있다.

또한 preflight와 실제 gateway dispatch 사이에 legal hold가 생기는 TOCTOU가 있다.
record 함수가 나중에 hold를 다시 검사하더라도 이미 외부 요청이 발생한다. 권위
계약의 deny-before-egress를 만족하지 않는다.

필수 조치: owner-side serializable preflight에서 source/asset/revision/content
rights와 active hold/suppression을 잠그고, 검증된 decision identity와 digest를
record 함수에 전달한다. record 함수는 합성 rights/timestamp/reviewer/license
row INSERT를 금지하고 exact existing rights FK만 허용해야 한다.

### AI-RUNTIME-FINAL-003 — fetch receipt가 항상 safety digest와 불일치함 (P0)

worker는 `build_pending_source_fetch`에서
`content-safety-v2:<contentSha>:<state>` digest를 계산하지만,
`persist_research_fetch` (`services/analysis-worker/src/analysis_source_fetch.rs:409`)
는 SQL 호출 시 `sha256("source-fetch-receipt:<fetch_id>")`를
`p_receipt_digest`로 전달한다. owner 함수는
`p_receipt_digest == content-safety-v2:<contentSha>:<state>`를 강제한다
(`0030...sql`의 `CONTENT_SAFETY_RECEIPT_MISMATCH` 검사).

따라서 정상 FETCH_URL도 ResearchArtifact commit 전에 mismatch로 롤백되며,
성공적인 provider/tool receipt 및 object-store/DB 원자 커밋을 입증할 수 없다.

필수 조치: PendingSourceFetch에 gateway/safety receipt를 명시적으로 보존하고
동일 digest를 response, owner function, artifact와 끝까지 전달한다. 단순한
fetch-id hash를 receipt로 대체하지 말고 positive/negative runtime test를 추가한다.

### AI-RUNTIME-FINAL-004 — redirect 정책/receipt chain이 wire 계약과 단절됨 (P0)

worker의 `read_source_response`는 한 번의 gateway GET만 수행하고 항상
`redirects: []`를 반환한다. `allowRedirects`는 최종 상태가 redirect일 때만
검사되며 gateway에는 전달되지 않는다. 반면 gateway
`services/egress-gateway/src/handlers/proxy_setup.rs`는 요청 플래그와 무관하게
최대 5회 redirect를 따라가고 각 hop을 검사하지만, chain의 from/to origin,
DNS/policy digest를 response receipt에 저장하지 않는다. `proxy_response_body.rs`
도 initial target만 receipt에 묶는다.

권위 계약은 매 hop의 scheme/host/DNS/IP/source-rights/byte budget 재검증과
typed redirect chain receipt를 요구한다. 현재는 redirect 허용 여부를 우회할 수
있고, positive/blocked/mixed-policy chain을 사후 검증할 증거가 없다.

필수 조치: HMAC-scoped typed gateway capsule에 redirect policy를 포함시키고,
각 hop 재검증 결과를 `redirects[]` 및 receipt digest에 저장한다. `false`이면
첫 redirect에서 deny하고, `true`이면 최대 5 hop 후 final origin까지 wire/DB
동일성을 검증한다.

### AI-RUNTIME-FINAL-005 — deterministic provider double이 fixture를 찾지 못하고 legacy generic validator를 허용함 (P0)

`services/analysis-worker/src/analysis_helpers.rs:295`는
`specs/agents/{agent_type}/{agent_type}-01-valid/provider-response.json`을
읽지만 실제 authority fixture는
`specs/agents/fixtures/{agent_type}/{agent_type}-01-valid/provider-response.json`
에 있다. 현재 경로는 존재하지 않아 `DETERMINISTIC_FIXTURE_MISSING`으로
abstain한다(`test -e`로 재현; actual fixture 경로만 존재).

경로를 고쳐도 fixture는 `status`, `abstention_reasons` 등의 legacy 공통 envelope이며
V2 `schemaVersion`/agent별 closed schema가 없다. 그런데
`validate_agent_output_for` (`analysis_helpers.rs:399-412`)는 schemaVersion이
없으면 generic v1 validator로 내려가 이를 허용한다. 이는 authority의
“declared per-agent provider-response.json을 반환하고 동일한 V2 schema를 먼저
검증” 계약을 충족하지 않으며, PDM evidence의 `providerTurns: 0`과도 일치한다.

필수 조치: fixture 경로/manifest를 고정하고 다섯 agent의 V2 fixture와 failure
fixture를 모두 closed schema로 변환한다. generic/legacy fallback을 제거하고
provider output validator → policy → proposal/source lineage를 동일 경로로
통과시키는 positive/negative 실행 증거를 남긴다.

### AI-RUNTIME-FINAL-006 — provider/runtime positive receipt 증거가 없음 (P1)

`implementation-evidence/provider-runtime-closure.md`는 코드/ACL 검사만
기록하며 실제 provider turn, source.fetch success, gateway receipt, cost
settlement, redirect/ratio negative와 clean replay의 live receipt를 제시하지
않는다. `implementation-evidence/runtime-journey-receipts/pdm-003...json`의
측정값도 `providerTurns: 0`이다. 따라서 provider receipt round-trip, one-byte
digest change, possible-send reconciliation, exact replay zero-dispatch를
현재 source에서 실측했다고 볼 수 없다.

필수 조치: 외부 provider를 호출하지 않는 authority-approved test double로도
실제 DB transaction/receipt를 생성해 positive와 각 failure state를 기록하고,
provider turn count, request/response/receipt digest, budget settlement, replay
zero-second-dispatch를 source digest에 바인딩한다.

### AI-RUNTIME-FINAL-007 — Brave discovery URL/순위 정책이 authority와 다름 (P1)

`build_fetch_output`는 `web.results[].url`을 `reqwest::Url`로 파싱해 host/path를
만들 뿐, discovery URL에 대해 HTTPS canonicalization, PUBLIC_RESEARCH DNS/IP
정책, canonical URL dedup을 재실행하지 않는다. 따라서 provider가 반환한 HTTP,
비정규화 또는 정책 위반 URL이 discovery metadata로 노출될 수 있다. 또한
`truncated = results.len() >= requested_limit`는 provider의 more-results 신호가
없는 정확히 N개 결과도 잘못 truncation으로 표시한다. authority는 canonical URL
dedup 후 첫 ordinal을 보존하고, provider more-results 또는 validated count >
limit일 때만 `truncated=true`로 요구한다.

필수 조치: 각 discovery URL에 대해 gateway와 동일한 canonical URL/DNS 정책을
재검증하고 중복을 제거한다. provider의 명시적 more-results 신호를 closed
adapter schema에 포함하거나, 그 신호가 없으면 false-positive truncation을
만들지 않는 보수적 규칙과 receipt binding을 정의한다.

## Confirmed strengths (non-blocking only after above repairs)

- capability preflight와 legal-hold 조건을 조회하는 owner function 및 analysis-worker
  EXECUTE ACL은 존재한다.
- Brave decoder는 현재 `BraveSearchResponse`/`BraveResult`에
  `deny_unknown_fields`를 사용해 일부 schema drift를 fail-closed한다.
- gateway는 redirect hop마다 `validate_target`를 호출하고 최대 5 hop을 제한하며,
  compressed/expanded byte header와 ratio guard를 노출한다.
- provider output/source-use/citation lineage와 omnichannel adapter의 typed
  receipt 구조는 소스에 존재한다.

이 강점들은 실제 receipt/manifest/archive 및 위 P0 계약 불일치를 해소했다는
증거가 아니며 LGTM 사유로 사용할 수 없다.

## Re-review gate

1. 위 P0-001~005를 구현하고 positive/negative runtime 증거를 생성한다.
2. source/evidence를 한 digest로 freeze하고 manifest/tree digest를 PASS시킨다.
3. clean extraction/member parity를 확인한 archive를 새로 만든다.
4. 변경 없는 최종 snapshot에 대해 독립 AI/runtime 리뷰를 다시 요청한다.
