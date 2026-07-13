@hard-gate @final @ops @security
Feature: 비용과 incident 통제는 보조 작업을 안전하게 중단한다

  # scenario-id: AC-BUDGET_AND_KILL_SWITCH-001
  Scenario: 100% 일일 모델 예산에서 선택적 AI 작업을 시작하지 않는다
    Given daily model budget used ratio가 1.0이다
    When OPTIONAL_LLM_RESEARCH task를 enqueue한다
    Then task는 BUDGET_BLOCKED 상태다
    And provider API 호출은 0회다
    And raw ingestion과 deterministic detection은 계속 가능하다

  # scenario-id: AC-BUDGET_AND_KILL_SWITCH-002
  Scenario: 이미 실행 중인 task도 비용 상한을 넘지 않는다
    Given agent task max cost가 200000 microunits이다
    When 예상 다음 call이 상한을 넘는다
    Then task는 partial untrusted output을 적용하지 않고 중단한다
    And 비용/중단 reason을 기록한다

  # scenario-id: AC-BUDGET_AND_KILL_SWITCH-003
  Scenario: source kill switch는 해당 source fetch만 중단한다
    Given source "pps_g2b_contracts" kill switch가 활성이다
    When scheduler가 fetch를 요청한다
    Then 네트워크 호출은 실행되지 않는다
    And 다른 source와 public read는 정책대로 계속된다

  # scenario-id: AC-BUDGET_AND_KILL_SWITCH-004
  Scenario: publication kill switch는 background consumer에도 적용된다
    Given ALL_PUBLICATION kill switch가 활성이다
    And publication event가 queue에 있다
    When consumer가 이벤트를 처리한다
    Then public revision commit/read model update를 하지 않는다
    And event를 성공 처리로 버리지 않고 policy-blocked 상태로 보존한다

  # scenario-id: AC-BUDGET_AND_KILL_SWITCH-005
  Scenario: kill switch 변경은 감사된다
    When 권한 있는 incident commander가 reason과 scope로 switch를 켠다
    Then actor, reason, time, scope, expiry/review가 append-only audit에 기록된다
