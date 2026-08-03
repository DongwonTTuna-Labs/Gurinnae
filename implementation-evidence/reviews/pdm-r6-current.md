# PdM 독립 구현 재검토 R6 (authority-v13 only)

`PDM_VERDICT: CHANGES_REQUIRED`

`REVIEWED_AT_UTC: 2026-07-19`
`AUTHORITY_ZIP_SHA256: 960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
`ROLE: PDM / CORE_JOURNEYS / OPERATIONS / MEASUREMENT`

## 결론

새 `flow-01..10-20260719.json`은 실제 PostgreSQL 18.4에서 generic journey
start/request/ACK의 receipt·audit·outbox·event·destination을 읽었다는 점과
stale expected-version의 SQLSTATE 40001/무변경 count를 보여준다. 그러나 각
authority flow의 사용자 여정 전체를 실행했다는 증거가 아니며, 10개 파일의
`operationId`는 DB 실행 결과가 아닌 생성 스크립트가 주입한 label이다. 따라서
R5의 PDM-R5-001은 닫히지 않는다. `pdm-003-observability-20260719.json`도
구조는 있으나 source/parser/rule 행이 관측 0건인데 `KNOWN/NONE`으로 기록되어
실제 SLI를 입증하지 못하고, 5개 행의 window가 한 시각의 snapshot이다. PDM-003도
닫히지 않는다.

## PDM-R6-001 — flow receipt가 authority flow를 실행하지 않음 (P0)

`scripts/generate_pdm_flow_evidence.py`의 `collect()`는 모든 행에서
`ops.acceptance_runtime_probe_v1(scenarioId)` 한 번을 호출한다. 이 owner
probe는 journey instance의 start/request/ACK를 수행할 뿐이다. SQL readback은
`operationId`를 SQL literal로 삽입하고 실제 operation audit/command를
검증하지 않는다. 현재 결과의 의미는 다음과 같다.

| Flow | evidence가 실제로 실행한 journey/도착점 | authority 정상 경로에서 아직 빠진 단계 |
|---|---|---|
| 01 | J-01, PUB-004 | 최신 revision·stale/evidence limitation·claim locator·reproduction/readback |
| 02 | J-02, PUB-005 | citation locator, rule/cohort/input digest, checksum/license download, fixed revision |
| 03 | J-05, SIG-002 | triage/task/case/evidence/response gate/dual review/publish projection(PUB-004) |
| 04 | J-01, PUB-004 | CAS-009 contact/legal gate→response request/token→scan→RSP-006/intake |
| 05 | J-08, COR-002 | independent decision→new publication revision→cache/API/download→subscriber notice |
| 06 | J-09, SRC-006 | schema diff/mapping→shadow parse→approval→bounded replay/backfill/checkpoint/freshness |
| 07 | J-07, REV-002 | immutable draft/gold-FP/shadow quality gate→activation→monitor/rollback |
| 08 | J-10, CAS-010::run-created | OIDC scope/step-up/SoD policy decision·denial·high-impact terminal receipt |
| 09 | J-02, PUB-005 | verification email→active→management/unsubscribe/suppression and invalid-link branch |
| 10 | J-12, OPS-004::commercial-health-inspected | incident scope/runbook→actual kill-switch activation/expiry/notice→recovery/resume/postmortem |

특히 Flow 03, 04, 09, 10은 결과 도착점 자체가 authority 문서의 완료
도착점과 다르다. Flow 01·02·05·06·07·08도 첫 handoff 하나만 읽었으므로
문서의 후속 화면·gate·destination을 검증하지 않는다. `normal.operationId`
값은 예를 들어 Flow 03의 `publishCase`처럼 보이지만 실제 DB receipt의
operation/command binding이 아니라 generator의 문자열이다.

필수 수정은 flow마다 실제 authority operation sequence를 실행하고, 각 edge의
서버 command/query operationId가 audit/receipt에 저장된 값과 일치함을
readback하는 것이다. 정상 branch의 최종 destination과 authority가 명시한
실패/복구 branch를 각각 독립 receipt chain으로 보존해야 한다. generic
journey ACK 또는 operation label만으로 flow closure를 선언할 수 없다.

## PDM-R6-002 — negative branch는 generic handoff conflict일 뿐임 (P1)

모든 파일의 negative branch가 동일하게
`request_journey_handoff_v1(i.version - 1, ...)`를 호출하고
`journey_version_conflict`를 확인한다. 이는 optimistic concurrency 센서로는
유효하지만, authority flow별 실패 조건을 검증하지 않는다. 예컨대 Flow 04의
expired token/file-scan 미완료, Flow 06의 parser mismatch/quarantine, Flow
07의 quality gate 실패, Flow 08의 assurance/SoD 거부, Flow 09의 invalid
verification/rate-limit, Flow 10의 broad switch two-person denial이 전혀
실행되지 않았다. 각 flow별 expected closed error와 forbidden domain/public
mutation zero proof가 필요하다.

추가로 generator는 `negative.pass`를 `negative_after == after`만으로 계산하고
`observedError`가 expected SQLSTATE/message인지 assert하지 않는다. outer
`pass`도 `True`를 직접 기록한다. 현재 파일의 40001 문자열은 관찰된 값이지만,
재실행 시 동일 오류 계약을 보장하는 validator가 없어 hard gate 증거로는
불충분하다.

## PDM-R6-003 — PDM-003 source/parser/rule 행은 false-known (P0)

`pdm-003-observability-20260719.json`의 measured 값은 `sourceRuns: 0`,
`sourceDocuments: 0`, `ruleRuns: 0`, `providerTurns: 0`이다. 그럼에도 현재
artifact는 source, parser-normalization, rules-editorial-public 행을
`status: KNOWN`, `reason: NONE`으로 기록한다. 이는 authority observability
계약의 fail-closed 의미와 맞지 않는다. 관측이 없으면 `NOT_APPLICABLE` 또는
명시적 `UNKNOWN`과 reason을 반환하고, freshness/parser/rule quality를
성공으로 세면 안 된다. 현재 generator 소스는 이 조건에서
`NOT_APPLICABLE/NO_SOURCE_OBSERVATIONS`를 만들도록 바뀌어 있어, artifact와
현재 generator가 재현되지 않는 추가 무결성 문제도 있다.

또한 다섯 행 모두 `windowStart == windowEnd`인 단일 timestamp snapshot이다.
authority SLO(availability, latency, lag, parser success, correction
propagation 등)의 numerator/denominator window를 측정하지 않으며, source·
parser·rule row의 0/0은 SLI 계산이 아니다. 최소 한 개의 유효한 observation
window(또는 명시적 NOT_APPLICABLE/UNKNOWN)를 실제 run으로 수집하고,
target/formula/observed/reason을 일치시켜야 한다.

## PDM-R6-004 — 공통 correlation/incident 링크는 있으나 의미적 연결이 부족 (P1)

PDM artifact의 `correlationId`와 Flow 10 receipt ID/digest 링크는 존재하고
PII label scan도 PASS다. 그러나 Flow 10이 실제 kill-switch가 아니라 J-12
commercial-health journey ACK이며, recovery receipt도 그 generic ACK를
가리킨다. 따라서 `injectedFault: stale-expected-version`을 incident
runbook·switch activation·public degraded notice·recovery/resume와 연결한
운영 사고 증거로 인정할 수 없다.

## 재검토 조건

1. authority flow별 실제 operation sequence와 최종 destination을 실행한
   clean PostgreSQL receipt bundle을 생성한다.
2. 각 flow의 고유 negative/recovery branch와 expected error, zero-mutation
   proof를 추가한다.
3. `operationId`·actor/session·input/expected-version·receipt/audit/outbox/
   event·destination가 실제 DB row readback으로 서로 일치하는지 검증한다.
4. PDM-003 다섯 행을 유효한 SLI window로 재수집하고, 관측 0건은
   `NOT_APPLICABLE/UNKNOWN`으로 fail-closed 처리한다.
5. 실제 kill-switch scope/expiry/SoD/degraded notice/recovery/resume 및
   postmortem audit을 같은 correlation ID로 연결한다.

위 조건을 source-tree digest와 함께 재검증하기 전에는 `PDM_VERDICT: LGTM`
또는 `VERDICT: ARTIFACT_READY`를 발행할 수 없다.
