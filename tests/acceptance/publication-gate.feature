@hard-gate @final @editorial @security
Feature: 공개 revision은 정확한 인간 검토와 정책 gate를 통과해야 한다
  공개는 AI나 UI 상태가 아니라 서버의 불변 정책 검사 결과여야 한다.

  Background:
    Given 합성 사건 "case_fixture_price_target"이 존재한다
    And 사건의 모든 공개 후보 claim은 존재하는 verified evidence를 참조한다
    And publication 정책 버전은 "editorial-1.0.0"이다

  # scenario-id: AC-PUBLICATION_GATE-001
  Scenario: 권한 있는 인간 편집자의 정확한 snapshot 승인으로 공개한다
    Given 현재 사건 버전은 12이다
    And 현재 review snapshot hash는 "snapshot_a"이다
    And actor type HUMAN인 EDITOR가 "snapshot_a"를 APPROVE했다
    And response와 legal 요구가 충족됐다
    And publication kill switch는 비활성이다
    When PUBLISHER가 expected case version 12와 "snapshot_a"로 공개를 요청한다
    Then 새 immutable PublicationRevision이 정확히 1개 생성된다
    And public read model은 그 revision만 노출한다
    And publication event와 audit event가 같은 transaction/outbox에서 기록된다

  # scenario-id: AC-PUBLICATION_GATE-002
  Scenario: 인간 승인이 없으면 공개하지 않는다
    Given 현재 snapshot에 대한 ReviewDecision이 없다
    When 공개를 요청한다
    Then 요청은 block code "MISSING_HUMAN_APPROVAL"로 거부된다
    And PublicationRevision은 생성되지 않는다
    And 사건 상태는 공개 상태로 바뀌지 않는다

  # scenario-id: AC-PUBLICATION_GATE-003
  Scenario Outline: 사람이 아닌 actor의 승인은 인정하지 않는다
    Given actor type이 <actor_type>인 approval이 있다
    When 공개를 요청한다
    Then 요청은 block code "MISSING_HUMAN_APPROVAL"로 거부된다

    Examples:
      | actor_type |
      | AGENT      |
      | SERVICE    |

  # scenario-id: AC-PUBLICATION_GATE-004
  Scenario: 승인 후 claim이 변경되면 승인도 stale이다
    Given "snapshot_a"가 승인됐다
    And claim text가 수정되어 현재 snapshot은 "snapshot_b"이다
    When "snapshot_a" 승인을 사용해 공개를 요청한다
    Then 요청은 block code "STALE_REVIEW_SNAPSHOT"으로 거부된다
    And 기존 approval을 "snapshot_b"에 자동 재연결하지 않는다

  # scenario-id: AC-PUBLICATION_GATE-005
  Scenario: approval이 revoke되면 공개하지 않는다
    Given 현재 snapshot에 대한 approval이 있었지만 revoked_at이 기록됐다
    When 공개를 요청한다
    Then 요청은 block code "MISSING_HUMAN_APPROVAL"로 거부된다

  # scenario-id: AC-PUBLICATION_GATE-006
  Scenario: legal review가 필요한 사건은 editor 승인만으로 공개하지 않는다
    Given 사건의 legal review requirement가 true이다
    And EDITOR approval만 존재한다
    When 공개를 요청한다
    Then 요청은 block code "LEGAL_REVIEW_REQUIRED"로 거부된다

  # scenario-id: AC-PUBLICATION_GATE-007
  Scenario: response requirement가 미완료면 공개하지 않는다
    Given response_required가 true이다
    And response request가 아직 전달되지 않았다
    When 공개를 요청한다
    Then 요청은 block code "RESPONSE_WINDOW_INCOMPLETE"로 거부된다

  # scenario-id: AC-PUBLICATION_GATE-008
  Scenario: unresolved blocking condition이 있으면 공개하지 않는다
    Given 연결된 signal에 "BUNDLE_UNKNOWN" blocker가 남아 있다
    When 공개를 요청한다
    Then 요청은 block code "UNRESOLVED_BLOCKING_CONDITION"으로 거부된다

  # scenario-id: AC-PUBLICATION_GATE-009
  Scenario: publication kill switch가 활성화되면 모든 approval이 있어도 공개하지 않는다
    Given 필요한 editor와 legal approval이 모두 있다
    And kill switch "ALL_PUBLICATION"이 활성이다
    When 공개를 요청한다
    Then 요청은 HTTP 423과 block code "KILL_SWITCH_ACTIVE"로 거부된다
    And override query parameter나 UI 역할로 우회할 수 없다
