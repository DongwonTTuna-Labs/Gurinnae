@hard-gate @final @supplemental @journey-graph @browser @postgresql
Feature: 12개 업무 여정은 명시적 129-edge graph와 실제 영수증으로 끝까지 실행된다

  Background:
    Given canonical 12개 journey와 129개 explicit edge가 같은 source digest로 컴파일돼 있다
    And Rust 1.97.0 서비스와 PostgreSQL 18.4 전체 migration과 SvelteKit production build가 실행 중이다
    And fixture는 입력에만 사용되고 action handler receipt와 browser destination은 실제 runtime 경계를 통과한다

  # scenario-id: AC-JOURNEY_GRAPH-001
  Scenario: product와 UI와 runtime edge registry는 정확히 12 journey 129 edge다
    When 네 registry의 edge identity와 tuple을 양방향 비교한다
    Then missing extra positional synthetic edge는 모두 0건이다

  # scenario-id: AC-JOURNEY_GRAPH-002
  Scenario: 모든 journey entry는 closed branch와 cross return을 거쳐 terminal에 도달한다
    When 12개 entry에서 success nonvalue recovery terminal을 탐색한다
    Then unreachable terminal과 무한 비소비 cycle은 0건이다

  # scenario-id: AC-JOURNEY_GRAPH-003
  Scenario: 모든 nonterminal node에는 실행 가능한 outgoing edge가 있다
    When branch selector와 compound source node를 확장한다
    Then handler가 없거나 selector가 비어 있는 nonterminal node는 0건이다

  # scenario-id: AC-JOURNEY_GRAPH-004
  Scenario: 129 edge resolver와 handler와 acceptance identity가 정확히 같다
    When compiled resolver registry와 runtime handler와 edge receipt를 비교한다
    Then 모든 edge는 정확히 하나의 typed resolver와 실행 receipt를 가진다

  # scenario-id: AC-JOURNEY_GRAPH-005
  Scenario: journey 확장은 기존 94 route surface를 바꾸지 않는다
    When source destination route와 parameter binding을 컴파일한다
    Then route 추가 삭제 fallback destination은 0건이다

  # scenario-id: AC-JOURNEY_GRAPH-006
  Scenario: cross journey return은 root subject owner due와 receipt를 보존한다
    When 각 callee의 success nonvalue recovery terminal에서 caller로 돌아온다
    Then root version digest owner due와 return receipt가 compiled binding과 같다

  # scenario-id: AC-JOURNEY_GRAPH-007
  Scenario: J-03 소명 요청은 J-11 승인과 delivery terminal 없이 전송되지 않는다
    When CAS-009에서 response request를 시작한다
    Then 승인되지 않은 직접 send path는 0건이고 RSP-001은 delivery receipt 뒤에만 열린다

  # scenario-id: AC-JOURNEY_GRAPH-008
  Scenario: J-05 triage의 다섯 결과는 서로 섞이지 않는다
    When DISMISS NEEDS_DATA MARK_DUPLICATE PROMOTE_TO_CASE LINK_TO_CASE를 각각 실행한다
    Then 각 결과의 owner terminal handoff와 destination은 closed selector와 같다

  # scenario-id: AC-JOURNEY_GRAPH-009
  Scenario: J-06은 J-10 조사와 J-03 소명을 왕복해 같은 사건으로 돌아온다
    When AI 조사와 새 response request branch를 각각 완료한다
    Then CAS-004와 CAS-008 return은 같은 case root와 validated terminal receipt를 가진다

  # scenario-id: AC-JOURNEY_GRAPH-010
  Scenario: J-07의 네 review 결정은 직접 publication을 우회하지 않는다
    When APPROVE CHANGES_REQUIRED REJECT RECUSE를 각각 제출한다
    Then APPROVE만 별도 publisher 승인으로 가고 나머지는 각 closed nonvalue recovery path로 간다

  # scenario-id: AC-JOURNEY_GRAPH-011
  Scenario: J-10 entry에서 검증된 evidence promotion까지 도달한다
    When bounded agent run을 완료하고 한 promotion candidate를 선택한다
    Then CAS-004에는 immutable source artifact와 Evidence binding이 함께 보인다

  # scenario-id: AC-JOURNEY_GRAPH-012
  Scenario: J-10 cancel과 uncertain outcome은 새 run이 아니라 reconcile한다
    When dispatch 전후 cancel과 provider outcome 불명확 상태를 각각 만든다
    Then definitive cancel 또는 same-run reconciliation만 허용되고 중복 provider call은 0건이다

  # scenario-id: AC-JOURNEY_GRAPH-013
  Scenario: J-10 citation promotion은 모든 source digest를 보존한다
    When validated citation을 authoritative Evidence로 승격한다
    Then run turn tool fetch artifact content locator와 resulting Evidence digest가 모두 결속된다

  # scenario-id: AC-JOURNEY_GRAPH-014
  Scenario: J-11 proposal entry는 durable effect receipt까지 실행된다
    When 승인 가능한 typed action을 draft preview quorum execution 순서로 처리한다
    Then HTTP나 queue acceptance가 아니라 definitive effect receipt만 J-11 success를 만든다

  # scenario-id: AC-JOURNEY_GRAPH-015
  Scenario: J-11 decision selector는 quorum policy rejection changes와 recusal을 분리한다
    When 모든 review selector를 같은 proposal source에서 실행한다
    Then resulting state owner handoff event와 receipt는 selector별 closed contract와 같다

  # scenario-id: AC-JOURNEY_GRAPH-016
  Scenario: J-11 withdrawal은 claim과 dispatch race에서 중복 효과를 만들지 않는다
    When draft pending claimed dispatching 경계에서 withdrawal을 경쟁시킨다
    Then 허용된 terminal 또는 reconciliation 하나만 남고 effect는 최대 한 번이다

  # scenario-id: AC-JOURNEY_GRAPH-017
  Scenario: J-11 dispatch 뒤 cancel은 authenticated reconciliation로 끝난다
    When provider effect 가능성이 있는 시점에 cancel timeout을 만든다
    Then same execution identity를 reconcile하고 새 idempotency root로 재실행하지 않는다

  # scenario-id: AC-JOURNEY_GRAPH-018
  Scenario: J-11 terminal은 정확한 origin screen과 subject로 돌아간다
    When 열 개 origin placement에서 action을 각각 완료한다
    Then terminal receipt와 focus destination은 최초 origin subject version digest를 보존한다

  # scenario-id: AC-JOURNEY_GRAPH-019
  Scenario: J-11 communication은 다섯 물리 milestone을 모두 구분한다
    When intent created sending provider accepted delivered read outcome을 기록한다
    Then provider accepted는 success가 아니고 delivered 또는 read receipt만 receiver terminal이다

  # scenario-id: AC-JOURNEY_GRAPH-020
  Scenario: J-12 commercial remediation은 owner acknowledgement로 닫힌다
    When OPS-004 blocker에서 INT-002 remediation task를 연다
    Then exact owner ACK와 qualified receipt가 없으면 다음 stage로 진행하지 않는다

  # scenario-id: AC-JOURNEY_GRAPH-021
  Scenario: J-12 qualified configured data ready 순서는 immutable evidence로만 전진한다
    When 각 predecessor receipt를 순서대로 추가한다
    Then predecessor 누락 stale unknown은 BLOCKED이고 stage를 추정하지 않는다

  # scenario-id: AC-JOURNEY_GRAPH-022
  Scenario: J-12 first paid value는 audited terminal pair 뒤에만 성립한다
    When paid evidence packet과 organization decision 또는 outbound delivery를 완료한다
    Then exact packet terminal pair와 cost closure가 함께 있을 때만 paid outcome fact가 생긴다

  # scenario-id: AC-JOURNEY_GRAPH-023
  Scenario: J-12 activation은 first value와 사용 milestone을 서로 바꾸지 않는다
    When paid value와 activation window 관측을 각각 기록한다
    Then activation formula policy cutoff와 observation multiset이 같은 receipt에 결속된다

  # scenario-id: AC-JOURNEY_GRAPH-024
  Scenario: J-12 retention은 고정 window와 repeat root를 사용한다
    When retention watch가 mature되기 전후 반복 paid workflow를 실행한다
    Then window 전에는 RETAINED가 아니고 repeat root는 이전 outcome을 재사용하지 않는다

  # scenario-id: AC-JOURNEY_GRAPH-025
  Scenario: J-12 at risk와 churn correction은 새 immutable episode를 남긴다
    When active reason closure와 churn 및 correction을 순서대로 기록한다
    Then 이전 episode를 덮어쓰지 않고 highest still proven milestone을 다시 계산한다

  # scenario-id: AC-JOURNEY_GRAPH-026
  Scenario: J-12는 mutable stage ledger를 만들지 않는다
    When qualification부터 retention까지 전체 경로를 실행한다
    Then stage는 signed facts에서 projection되고 generic current-stage write는 0건이다

  # scenario-id: AC-JOURNEY_GRAPH-027
  Scenario: J-12의 J-10은 선택이고 J-11은 모든 외부 effect에 필수다
    When human-only evidence path와 AI-assisted path를 각각 실행한다
    Then 둘 다 same paid packet contract로 합류하고 action effect는 반드시 J-11 approval을 통과한다

  # scenario-id: AC-JOURNEY_GRAPH-028
  Scenario: J-12 paid terminal pair는 organization decision과 delivery를 혼합하지 않는다
    When 두 terminal kind의 success nonvalue reconciliation을 각각 기록한다
    Then typed candidate와 binding relation이 정확히 하나이며 다른 kind receipt는 대체할 수 없다

  # scenario-id: AC-JOURNEY_GRAPH-029
  Scenario: J-03 동시 제출은 token-free v2 이벤트와 owned-intake response를 정확히 한 번 만든다
    When 같은 request version receipt digest와 Idempotency-Key로 submitResponse를 64개 동시에 실행한다
    Then submission과 세 v2 event와 editorial response와 owned-intake receipt는 각각 한 건이고 나머지 응답은 byte-identical replay다

  # scenario-id: AC-JOURNEY_GRAPH-030
  Scenario: J-03 owned-intake crash 경계에는 partial response graph가 남지 않는다
    When inbox claim source reload response insert reciprocal pointer audit outbox terminalization 각 경계에서 crash를 주입하고 같은 event를 재실행한다
    Then 매 crash 전 transaction은 전부 rollback되고 최종에는 완전한 APPLIED graph 한 개 또는 저장된 no-op result 한 개만 있다

  # scenario-id: AC-JOURNEY_GRAPH-031
  Scenario: J-03 event replay는 envelope digest와 reciprocal binding을 모두 비교한다
    When 같은 event ID와 exact envelope를 재생하고 다시 한 바이트 바뀐 envelope와 distinct byte-equal event를 보낸다
    Then exact replay는 0 write이고 changed envelope는 EVENT_REPLAY_CONFLICT이며 distinct byte-equal event는 NO_OP_ALREADY_MATERIALIZED만 저장한다

  # scenario-id: AC-JOURNEY_GRAPH-032
  Scenario: delivery observation의 stale branch와 DB-owned time은 외부 효과를 과장하지 않는다
    When applied observation과 out-of-order stale observation 그리고 악의적인 과거 미래 시각 입력을 각각 시도한다
    Then applied는 audit 1 outbox 1이고 stale은 audit 1 outbox 0이며 observedAt 입력은 schema와 SQL signature에 존재하지 않고 저장 시각은 권위 receipt 또는 DB transaction bound 안이다

  # scenario-id: AC-JOURNEY_GRAPH-033
  Scenario: safe retry는 최신 reconciliation decision composite 하나로만 다음 ordinal을 연다
    When valid proof를 64개 동시에 claim하고 cross-delivery stale digest-only ambiguous proof를 각각 제출한다
    Then 최신 RETRY_SCHEDULED decision을 exact composite FK로 가리키는 다음 ordinal 한 건만 생기고 나머지 proof는 attempt 0건이다

  # scenario-id: AC-JOURNEY_GRAPH-034
  Scenario: response portal은 effective due와 DB OTP verifier 하나만 권위로 사용한다
    When due_at 과거 effective_due_at null과 미래와 과거 timely pending extension 및 OTP 64-way race를 실행한다
    Then shared resolver의 open closed 결과가 계약과 같고 caller boolean 없이 purpose-HMAC verifier 일치 한 건만 active session을 만든다

  # scenario-id: AC-JOURNEY_GRAPH-035
  Scenario: PostgreSQL catalog는 J-03 routine type event admission과 ACL을 정확히 닫는다
    When PostgreSQL 18.4 pg_class pg_type pg_attribute pg_proc aclexplode와 event_types를 검사한다
    Then 0027 관계는 정확히 22개이고 두 materializer routine과 typed composites가 하나씩이며 token-free v2 세 event와 editorial materialized v1 event만 활성이고 세 token-bearing v1 event와 old boolean OTP routine은 runtime EXECUTE 0이며 portal resolver mandatory caller 전체의 routine/type/ACL set이 exact하다
