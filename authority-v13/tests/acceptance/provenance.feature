@hard-gate @final @data @editorial
Feature: 공개 주장은 원본 bytes까지 재현 가능한 근거 사슬을 갖는다

  Background:
    Given 합성 price target fixture가 저장소에 있다

  # scenario-id: AC-PROVENANCE-001
  Scenario: raw payload hash를 검증하고 보존한다
    When fixture payload를 수집한다
    Then 계산한 SHA-256은 SourceDocument.content_sha256과 같다
    And immutable raw object를 같은 hash로 다시 읽을 수 있다
    And payload 내용은 parser가 바꾸지 않는다

  # scenario-id: AC-PROVENANCE-002
  Scenario: 정규화 핵심 필드마다 원본 locator가 있다
    When price target 계약을 정규화한다
    Then contract amount, quantity, unit price, VAT, agency, supplier 필드에 provenance가 있다
    And 각 provenance는 source_document_id, locator, raw_value_hash, parser version, transform version을 포함한다
    And locator로 얻은 raw value의 hash가 기록과 같다

  # scenario-id: AC-PROVENANCE-003
  Scenario: signal의 입력과 규칙을 재현한다
    When PRICE_OUTLIER 1.0.0을 실행한다
    Then signal은 exact input IDs와 input hash를 포함한다
    And 같은 정렬·입력·버전으로 다시 실행한 metrics와 output hash가 같다

  # scenario-id: AC-PROVENANCE-004
  Scenario: 존재하지 않는 evidence ref를 거부한다
    Given draft claim이 "evidence_missing"을 참조한다
    When claim을 VERIFIED로 변경하려 한다
    Then command는 referential-integrity error로 거부된다
    And 사건 상태는 바뀌지 않는다

  # scenario-id: AC-PROVENANCE-005
  Scenario: evidence가 locator를 갖지 않으면 public claim을 지지할 수 없다
    Given evidence source locator가 null이다
    When publication readiness를 평가한다
    Then claim은 readiness를 통과하지 못한다

  # scenario-id: AC-PROVENANCE-006
  Scenario: publication이 source freshness와 hash를 포함한다
    Given 사건이 모든 review gate를 통과했다
    When PublicationRevision을 생성한다
    Then revision의 source_freshness에 source ID, upstream published time, retrieval time, content SHA-256이 있다
    And revision content hash가 canonical content와 같다
