# AI/runtime fresh re-review — current tree (2026-07-20)

권위 ZIP: `gurine-codex-authority-pack-v13.0.0-20260712.zip`
(`sha256:960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`).
이 리뷰는 source-fetch/redirect/fixture/validator/safety-receipt 수정 이후의
현재 working tree를 다시 읽은 독립 검토이며 구현 파일은 수정하지 않았다.

## Verdict

```text
AI_VERDICT: CHANGES_REQUIRED
```

## Resolved since prior review

- `PendingSourceFetch`가 `content_safety_receipt_sha256`를 보존하고
  `persist_research_fetch`가 이를 owner function에 그대로 전달한다. 이전의
  고정 `sha256("source-fetch-receipt:<id>")` 불일치는 제거됐다.
- worker가 `x-gurine-allow-redirects`를 전송하고 gateway가 이를 거부/허용하며,
  최대 5-hop URL chain을 response/replay header로 반환한다.
- deterministic fixture 경로가 실제
  `specs/agents/fixtures/{agent}/{agent}-01-valid/provider-response.json`로
  수정됐고 generic/legacy output validator fallback은 명시적으로 거부된다.

## Blocking findings

### AI-RUNTIME-R2-001 — rights decision이 여전히 asset에 실바인딩되지 않음 (P0)

`ops.assert_research_fetch_rights_v1`는 SOURCE_ACCESS capability row를 조회하지만
dimensions를 `access/private/modelEgress/modelUse=ALLOW`로 합성한다
(`db/migrations/0030_v13_submission_session_hardening.sql:2254-2288`).
`ops.record_research_fetch_v1`도 그 capability UUID를 새
`raw.asset_rights_decisions.id`로 재사용하면서 asset id/revision/content hash에
대한 owner-approved 기존 decision FK를 전달하지 않는다. license evidence,
legal basis, reviewer와 effective timestamp도 fetch 시점에 새로 채운다.
따라서 source access 허가만으로 model egress/use가 허용되고, 실제 asset rights
decision이 DENY/UNKNOWN이어도 ResearchArtifact와 MODEL_INPUT lineage를 만들 수
있다.

추가로 동일한 active capability를 두 번째 FETCH_URL에서 사용하면 같은
`v_rights_id`를 새 artifact rights row의 PK로 다시 INSERT하게 되어, 서로 다른
asset에 하나의 capability UUID를 공유하는 구조적 충돌도 발생한다.

필수 조치: gateway 이전 serializable owner preflight에서 정확한 asset identity와
rights decision `(asset_id, revision, sha256, version, decision_sha256)` 및 active
legal hold/suppression을 잠그고, record 함수는 그 exact FK만 수용해야 한다.

### AI-RUNTIME-R2-002 — legal-hold preflight에 TOCTOU와 asset scope 누락 (P0)

현재 capability 조회는 source id에 대한 `editorial.legal_holds.affected_ids`
배열만 확인한다. URL content asset은 아직 생성되지 않았으므로 asset/document
hold anchor를 검사하지 않으며, preflight 이후 hold가 활성화돼도 gateway 요청이
먼저 나갈 수 있다. record 함수의 사후 재검사는 이미 발생한 외부 egress를
취소하지 못한다. 권위의 deny-before-egress/hold precedence를 입증할
serializable lock 또는 reservation receipt가 없다.

### AI-RUNTIME-R2-003 — redirect chain은 전달되지만 per-hop authority receipt가 아님 (P1)

gateway가 chain URL 문자열만 `x-gurine-source-fetch-redirect-chain`으로 반환한다.
각 hop의 status, from/to origin, DNS decision digest, policy decision digest를
typed `redirects[]`로 만들지 않고, chain 자체가 gateway receipt digest에 포함되지
않는다(`proxy_response_body.rs` receipt는 idempotency/target/status/body만 해시).
gateway `validate_target` 호출은 존재하지만, source worker가 받은 chain이 실제
재검증 결과와 동일하다는 cryptographic binding이 없다.

### AI-RUNTIME-R2-004 — deterministic provider double은 여전히 V2 positive fixture를
생성하지 못함 (P0)

경로와 fallback guard는 고쳐졌지만 실제 fixture
`specs/agents/fixtures/market-researcher/market-researcher-01-valid/provider-response.json`
는 `status`, `abstention_reasons`, `comparables` legacy envelope이며
`schemaVersion`, `outcome`, `investigationsPerformed`, `nextActions`,
`abstentionReasons` 같은 V2 필드가 없다. 따라서 수정된 validator가 이를 즉시
`AGENT_OUTPUT_SCHEMA_INVALID`로 거부하고, deterministic 환경에서 성공적인
provider-shaped V2 turn을 만들지 못한다. `pdm-003-observability-20260719.json`
도 `providerTurns: 0`이다.

필수 조치: 다섯 agent의 valid/failure fixture를 V2 closed schema로 재작성하고,
실제 deterministic run의 provider turn, output validation, proposal/source-use
lineage receipt를 생성해 증명한다.

### AI-RUNTIME-R2-005 — source/evidence/manifest digest가 다시 깨짐 (P0)

현재 실행한 `sha256sum --check MANIFEST.sha256`는 20개 이상 변경 파일에서
실패했으며, `python3 -B scripts/authority_tree_digest.py`는
`apps/review-console/src/routes/internal/operations/budgets/screen.ts` manifest
mismatch에서 중단했다. 최근 source-fetch, gateway, analysis helper 및 여러 UI/
runtime receipt 변경이 manifest에 반영되지 않았다. 따라서 현재 source와
runtime evidence/archive가 하나의 freeze digest로 묶였다는 증거가 없다.

필수 조치: 구현을 멈추고 source digest를 고정한 뒤 모든 receipt/CAS/PDM 증거,
`MANIFEST.md`, `MANIFEST.sha256`, authority tree digest, source-tree archive를
동일 snapshot에서 재생성하고 clean extraction/member parity를 검증한다.

## Verified checks (not sufficient for LGTM)

- safety receipt 전달 경로와 redirect allow/deny 헤더는 소스상 연결됐다.
- output validator의 schemaVersion missing legacy fallback은 제거됐다.
- gateway redirect hop count는 5로 제한되고 target validation을 반복한다.

이 checks만으로 rights binding, provider positive runtime, 또는 freeze gate가 닫힌
것은 아니다. 위 P0 blockers가 해결되고 동일 digest로 fresh evidence가 생성될
때까지 LGTM을 보류한다.
