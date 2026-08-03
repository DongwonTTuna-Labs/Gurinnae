# AI agent/runtime·multimodal·omnichannel 독립 리뷰 (2026-07-20)

Authority: `gurine-codex-authority-pack-v13.0.0-20260712.zip` only
(`sha256:960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`).
This is a read-only review of the current worktree and checked-in evidence. 리뷰어는
source/spec/DB를 수정하지 않았다.

## Verdict

```text
AI_VERDICT: CHANGES_REQUIRED
```

실제 Rust dispatcher, typed tool adapters, source-use/citation lineage, CAS-010/011
view-model, 멀티모달 parser runtime, 사람 승인 뒤 omnichannel delivery 코드는 존재한다.
그러나 현재 tree는 AI hard gate를 닫을 수 없다. 아래 P0 항목을 수정하고 단일 freeze에서
재검증해야 한다.

## Blocking findings

### AI-RUNTIME-P0-001 — source.fetch가 외부 fetch 전에 권리·hold를 검증하지 않고, DB가 synthetic ALLOW 권리를 만든다

증거:

- `services/analysis-worker/src/analysis_source_fetch.rs:92-137`는 gateway 응답을 받은 뒤
  content scanner를 실행한다. dispatch 전에 current source-access/model-use rights,
  legal-hold, capability activation을 조회하거나 binding하지 않는다.
- 같은 파일 `build_pending_source_fetch`는 `rights_id`, `rights_sha256`, 고정
  `occurred_at`을 content digest로부터 계산하고 모든 rights를 `ALLOW`로 구성한다.
- `db/migrations/0030_v13_submission_session_hardening.sql:2254-2470`
  `ops.record_research_fetch_v1`는 `raw.asset_rights_decisions`에
  `PUBLIC_RESEARCH`, `GLOBAL`, `GRANT`, 9개 `ALLOW`를 자동 INSERT하고 reviewer를
  `agent_runs.created_by`에서 가져온다. rights decision의 legal evidence/approval/
  execution/hold 검증 없이 artifact를 저장한 뒤 권리를 부여하는 경로다.
- 같은 함수는 `v_now := 2026-01-01 + digest-derived seconds`로 timestamp를
  합성한다. authority `network-provider.yaml` 및 acceptance
  `AC-AI_MULTIMODAL_ADDENDUM-004,009,010,012`는 실제 owner decision, source rights,
  hold와 authenticated receipt를 요구하며 synthetic rights/timestamp/digest를 금지한다.

영향: 권리 거부·만료·법적 보류가 있는 URL도 fetch가 외부로 나간 뒤 synthetic GRANT로
model input/ResearchArtifact가 될 수 있다. `expired or denied rights` negative case가
실패하고 외부 부작용 전에 fail-closed가 보장되지 않는다.

필수 수정: gateway dispatch 전 exact source asset/revision 또는 approved
PUBLIC_RESEARCH capability/rights decision을 owner relation에서 SERIALIZABLE로
확인하고 hold/suppression을 적용한다. `record_research_fetch_v1`는 권리행을 합성하지
말고 검증된 `(asset_id, revision, hash, decision_version, decision_sha256)`를 받아
FK로만 연결하며, 실제 gateway receipt/clock/price evidence만 저장해야 한다.

### AI-RUNTIME-P0-002 — redirect와 네트워크 byte/time 정책이 권위 계약과 닫히지 않았다

증거:

- `services/analysis-worker/src/analysis_source_fetch.rs:54-58,95-123,249-273`는
  `allow_redirects=true`를 항상 `SOURCE_REDIRECT_POLICY_UNSUPPORTED`로 거부하고,
  gateway에는 단일 target만 전달한다.
- `services/egress-gateway/src/handlers/mod.rs:503-513`의 upstream client는
  redirect를 `Policy::none()`으로 거부하며 redirect chain을 재검증/영속화하지 않는다.
- `services/egress-gateway/src/handlers/proxy_response_body.rs`는 expanded body
  limit만 chunk로 확인한다. compressed/expanded byte counters 및 ratio 100 정책이
  없고 analysis client는 `timeout=120s`다.
- 권위 `specs/agents/addendum-v2/network-provider.yaml:18-31,51`는 매 redirect
  scheme/host/DNS/IP/rights/byte 재검증(최대 5회), connect 5s/total 15s,
  compressed·expanded bound와 ratio 100을 요구한다.

영향: 허용된 정상 redirect도 구현되지 않아 필수 FETCH_URL 경로가 성공할 수 없으며,
압축 bomb/장시간 응답 정책도 acceptance-004의 gateway 계약을 충족하지 않는다.

필수 수정: redirect마다 canonical URL/DNS/IP/rights를 재검증하고 최대 5회 chain과
receipt digest를 반환·저장한다. streaming compressed/expanded counters, ratio 100,
connect 5s/total 15s를 gateway와 worker 양쪽에서 강제하고, 실패를 typed
RENDER_REQUIRED/QUARANTINED/OUTCOME_UNKNOWN으로 남긴다.

### AI-RUNTIME-P0-003 — 동일 freeze 증거가 유효하지 않다

증거:

- 현재 `sha256sum --check MANIFEST.sha256`는 `services/ingest-worker/src/ingest_jobs.rs`
  하나에서 mismatch를 보고한다.
- `python3 -B scripts/authority_tree_digest.py`는
  `MANIFEST mismatch before tree digest: services/ingest-worker/src/ingest_jobs.rs`
  로 종료한다.
- checked-in `runtime-journey-receipts/flow-01..10` 및 `pdm-003`는 모두 source
  digest `489a5449aae43b854bf80ea4f3c646a88f0d46f655ae16cd9c8944c70466a9db`를
  주장하지만, 현재 manifest가 깨져 이 digest를 재현할 수 없다.
- `runtime-traces/cas-010-authenticated.json`/`cas-011-authenticated.json`은
  positive authenticated observation을 포함하지만 source-tree digest, VM digest,
  graph/visualization digest를 기록하지 않는다. 따라서 현재 source와 동일 freeze의
  CAS parity 증거가 아니다. 이전 `cas-010.json`/`cas-011.json`은 모든 section이
  `BLOCKED`이고 `errorSummary:true`다.

영향: 현재 archive/tree가 실제로 검증된 AI CAS·dispatcher·omnichannel 코드와 같은
  바이트인지 증명할 수 없다. MANIFEST/authority digest가 실패한 상태에서는 hard gate
  및 `ARTIFACT_READY`를 주장할 수 없다.

필수 수정: source/evidence를 중지하고 source tree를 freeze한 뒤 MANIFEST를 재생성한다.
모든 journey/PDM 및 CAS authenticated traces를 같은 digest와 visualization/provenance
data/graph digest에 묶어 재생성하고, clean-extraction archive에서 manifest와 runtime
gate를 다시 실행한다.

### AI-RUNTIME-P0-004 — development/test deterministic double이 선택된 agent의 V2 output 계약을 우회한다

증거:

- `services/analysis-worker/src/analysis_helpers.rs:290-308`의 `deterministic_output`
  은 `schemaVersion`이나 선택 agent의 `comparables`/`hypotheses`/`challenges`/
  `claims`/`claimResults`를 만들지 않고 구형 `status`, `abstention_reasons`,
  `recommended_actions` 형태만 반환한다.
- 같은 파일 `validate_agent_output_for:395-438`는 `schemaVersion`이 없으면
  `validate_agent_output`라는 generic v1 validator로 분기한다. 따라서
  development/test provider-double은 addendum의 selected-agent exact schema를
  검증하지 않는다.
- `services/analysis-worker/src/analysis_job_persistence.rs:1-22`의
  `persist_agent_suggestion`는 이 generic output을 별도 legacy
  `ops.agent_suggestions` row로 저장한다. production V2 proposal insertion과
  동일한 completion에서 중복/opaque suggestion이 생기며, CAS-011의 typed
  proposal/citation set-equality를 깨뜨릴 수 있다.

영향: `AC-AI_MULTIMODAL_ADDENDUM-005,009,020`이 요구하는 provider-double과
production path parity, exact output schema, proposal zero-on-failure가 보장되지 않는다.

필수 수정: deterministic double도 registry가 선택한 V2 schema와 동일한 closed
output을 생성하고 generic v1 fallback을 제거한다. proposal은 단일 typed
`AgentProposalV2` insert path만 사용하며 legacy suggestion 자동 insert를 제거하거나
명시적 compatibility projection으로 격리한다. 5개 agent 각각에 double/tool-call/
final-output acceptance를 재실행한다.

### AI-RUNTIME-P0-005 — Brave discovery response가 closed provider schema drift를 fail-closed하지 않는다

증거:

- `services/analysis-worker/src/analysis_source_fetch.rs:304-319`는
  `web.results`의 `title`, `url`, `description`만 선택하고 provider response의
  추가/누락 필드를 무시한다. `web.results`가 없거나 배열이 아니어도 `unwrap_or_default()`로
  빈 검색 결과를 정상 응답처럼 만든다.
- 권위 `specs/agents/addendum-v2/network-provider.yaml`의
  `search_discovery_provider_registry.response_mapping`은 required `title,url`,
  optional `description,age` 이외 provider field를 adapter-version fixture에서
  명시 승인하기 전까지 거부하고 `PROVIDER_SCHEMA_DRIFT`를 내도록 한다.

영향: Brave API schema drift/부분 응답이 zero-result discovery로 가장되어 model input
또는 다음 FETCH_URL 정책 판단을 오염시킨다. provider schema drift hard case가
실패한다.

필수 수정: `serde(deny_unknown_fields)`에 준하는 exact typed response decoder를
사용하고 required/optional shape, truncation signal, URL canonical/DNS policy를 모두
검증한다. drift·missing results는 빈 성공이 아닌 typed `PROVIDER_SCHEMA_DRIFT`로
receipt와 reconciliation을 남긴다.

## Non-blocking verified observations (recheck required after fixes)

- `services/analysis-worker/src/analysis_runtime_bridge.rs`와
  `analysis_provider_output_validation.rs`는 agent별 schema, snapshot/source-use,
  citation, proposal validation, bounded turn/tool count를 실제 Rust path에서 수행한다.
- `services/control-api/src/service/query_analysis_vm.rs`,
  `query_analysis_detail.rs`, `query_analysis_provenance.rs`는 CAS-010/011용 typed
  visualization, accessible table, provenance graph digest를 생성한다. 현재
  positive trace에 digest binding이 없으므로 freeze 후 재검증이 필요하다.
- `services/notification-worker/src/handlers/delivery.rs`와
  `services/egress-gateway/src/communication_adapter.rs`는 Email, Telegram,
  WhatsApp, LINE, SMS, Kakao를 분리한 typed adapter와 idempotency key를 사용한다.
  `ops.claim_outbound_delivery_attempt`는 APPROVED rendering, endpoint/provider
  revision, preflight, suppression/opt-out, kill-switch를 claim 시 확인한다.
- `services/notification-worker/src/notification_typed_delivery_body.rs`는
  승인된 encrypted rendering만 복호화하고 provider 오류를 reconciliation으로 남긴다.
  이 경로는 위 freeze/rights gate가 닫힌 뒤에만 LGTM 근거로 사용할 수 있다.

## Required re-review gate

1. P0-001의 owner rights/hold preflight와 non-synthetic artifact receipt를 구현하고
   redirect/streaming policy를 authority와 동일하게 닫는다.
2. 단일 source freeze에서 `make manifest`, `sha256sum --check MANIFEST.sha256`,
   `scripts/authority_tree_digest.py`를 PASS시킨다.
3. 같은 source digest로 CAS-010/011 authenticated traces, journey/PDM receipts,
   provider/omnichannel evidence를 재생성한다.
4. 모든 hard gate 및 clean-extraction source archive를 다시 실행한다.
5. 위 변경이 없는 동일 source/evidence에 대해 fresh independent AI review를 요청한다.

Until all five steps pass, `AI_VERDICT: LGTM_NO_BLOCKING` and
`VERDICT: ARTIFACT_READY` are forbidden.
