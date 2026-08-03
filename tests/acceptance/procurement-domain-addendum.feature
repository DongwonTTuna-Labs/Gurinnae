@hard-gate @final @supplemental @procurement-domain @data @editorial
Feature: 조달 원본에서 사건·소명·내보내기까지 revision과 불확실성을 보존한다

  # scenario-id: AC-PROCUREMENT-DOMAIN-001
  Scenario: KONEPS 공고 변경은 원본 revision을 덮어쓰지 않는다
    Given 같은 공고 번호와 차수의 합성 KONEPS 공고 원본 revision 1과 2가 있다
    And 두 revision은 각각 source document, source asset revision, record digest와 effective time을 가진다
    When 공고 normalizer가 승인된 mapping version으로 두 원본을 처리한다
    Then ProcurementNotice revision 1과 2가 별도 immutable row로 저장된다
    And revision 2의 predecessor revision ID와 digest는 revision 1과 정확히 같다
    And title, agency, amount, published time마다 exact source locator가 있다

  # scenario-id: AC-PROCUREMENT-DOMAIN-002
  Scenario: 계약 변경은 앞뒤 계약 revision과 하나의 amendment로 닫힌다
    Given 합성 KONEPS 계약 baseline과 연속된 change record 두 개가 있다
    When contract normalizer가 세 record를 처리한다
    Then ProcurementContract revision은 1, 2, 3으로 연속된다
    And amendment 1은 contract revision 1과 2를 exact digest로 연결한다
    And amendment 2는 contract revision 2와 3을 exact digest로 연결한다
    And previous amount와 new amount는 인접 contract revision에서만 계산된다

  # scenario-id: AC-PROCUREMENT-DOMAIN-003
  Scenario: source effective time이 없으면 수집 시각으로 채우지 않는다
    Given KONEPS change record에 chgDt와 rgstDt가 모두 없다
    When source revision을 보존한다
    Then effective time status는 "UNKNOWN"이다
    And retrievedAt이나 checkpoint watermark를 effective time으로 복사하지 않는다
    And 시간 창이나 amendment 순서가 필요한 detection은 "EFFECTIVE_TIME_UNKNOWN"으로 BLOCKED된다

  # scenario-id: AC-PROCUREMENT-DOMAIN-004
  Scenario: 공고와 계약 당사자로 bidder participation을 추정하지 않는다
    Given base KONEPS notice와 contract connector만 활성화됐다
    And 계약 record에 한 업체 이름이 있다
    When LOW_BID_COMPETITION과 RESTRICTIVE_SPECIFICATION 입력을 만든다
    Then BidderParticipation row는 0개이다
    And 유효 입찰자 수를 1 또는 0으로 합성하지 않는다
    And 두 규칙은 "BIDDER_PARTICIPATION_COVERAGE_UNAVAILABLE"로 BLOCKED된다

  # scenario-id: AC-PROCUREMENT-DOMAIN-005
  Scenario: 계약 체결 기반 award는 완전한 낙찰 평가로 표시하지 않는다
    Given 공고 revision과 정확히 연결되고 구조화된 계약 업체가 있는 합성 contract conclusion record가 있다
    When Award revision을 생성한다
    Then award basis는 "CONTRACT_CONCLUSION"이다
    And coverage는 "PARTIAL"이다
    And losing bidders, bid rank와 complete evaluation이 없다는 limitation이 함께 저장되고 표시된다

  # scenario-id: AC-PROCUREMENT-DOMAIN-006
  Scenario: 같은 상호나 opaque corpList는 supplier를 자동 merge하지 않는다
    Given 정규화 상호가 같은 두 KONEPS supplier candidate가 있다
    And authoritative identifier는 없고 corpList는 승인된 parser 없이 opaque string이다
    When identity resolution 후보를 계산한다
    Then 두 candidate의 identity status는 "AMBIGUOUS" 또는 "CANDIDATE"이다
    And canonical supplier binding이나 relationship assertion을 만들지 않는다
    And raw corpList를 delimiter 추측으로 분리하지 않는다

  # scenario-id: AC-PROCUREMENT-DOMAIN-007
  Scenario: supplier merge는 exact candidate와 evidence decision history를 남긴다
    Given 검증된 authoritative identifier와 locator가 일치하는 supplier candidate 두 개가 있다
    When 권한 있는 actor가 expected candidate set digest로 MERGE를 결정한다
    Then 하나의 append-only SupplierIdentityResolutionDecision이 저장된다
    And candidate revision/digest, source locator, actor, reason, prior decision digest와 target supplier ID가 receipt에 있다
    And 같은 idempotency key와 bytes의 replay는 첫 receipt와 byte-identical하다

  # scenario-id: AC-PROCUREMENT-DOMAIN-008
  Scenario: 잘못된 supplier merge의 split은 공개 revision을 조용히 바꾸지 않는다
    Given merged supplier를 참조하는 공개 revision 세 개가 있다
    When 권한 있는 actor가 exact prior decision digest로 SPLIT을 결정한다
    Then 둘 이상의 새 canonical supplier와 append-only split decision이 생긴다
    And owner와 dueAt이 있는 correction impact task가 생성된다
    And 기존 공개 revision 세 개는 수정되거나 삭제되지 않는다

  # scenario-id: AC-PROCUREMENT-DOMAIN-009
  Scenario: ownership와 management assertion은 verified locator와 독립 결정을 요구한다
    Given supplier ownership assertion과 management assertion draft가 있다
    When exact evidence revision과 locator 없이 VERIFIED로 결정하려 한다
    Then 두 결정은 거부되고 assertion은 PENDING이다
    When 독립 reviewer가 verified parties, exact evidence locators와 expected assertion digest를 승인한다
    Then 새 immutable assertion revision과 verification receipt가 저장된다
    And 상충하는 current assertion이 있으면 둘 다 보존되고 현재 상태는 "CONFLICTED"이다

  # scenario-id: AC-PROCUREMENT-DOMAIN-010
  Scenario Outline: 모든 detection rule은 정상 설명·coverage·반대 근거를 같은 digest에 묶는다
    Given <rule_id> version 1.0.0의 immutable input snapshot이 있다
    And material source coverage와 grouping identity가 모두 VERIFIED이고 CURRENT이다
    When rule을 재현한다
    Then output은 closed ProcurementSignalExplanationV1을 만족한다
    And ordinary-language summary, exact fact revisions, cohort와 exclusions, coverage, counter-evidence search status와 unknowns가 있다
    And nonConclusion은 위법·부패·의도·특혜·과실을 확정하지 않는다고 명시한다
    And persisted explanation digest와 재계산 digest가 같다

    Examples:
      | rule_id                        |
      | PRICE_OUTLIER                  |
      | CONTRACT_SPLITTING_PATTERN     |
      | REPEATED_SINGLE_SOURCE         |
      | SUPPLIER_CONCENTRATION         |
      | LOW_BID_COMPETITION            |
      | RESTRICTIVE_SPECIFICATION      |
      | CONTRACT_AMENDMENT_ESCALATION  |
      | YEAR_END_SPENDING_SPIKE        |
      | NEW_SUPPLIER_DEPENDENCE        |
      | SHARED_SUPPLIER_IDENTITY       |

  # scenario-id: AC-PROCUREMENT-DOMAIN-011
  Scenario Outline: material identity ambiguity는 모든 관련 규칙에서 fail-closed다
    Given <rule_id> 입력의 agency 또는 supplier grouping identity가 "AMBIGUOUS"이다
    When detection outcome을 계산한다
    Then outcome은 "BLOCKED"이다
    And blocker는 "IDENTITY_AMBIGUOUS"이다
    And signal, public claim, supplier graph 또는 zero-valued metric을 만들지 않는다

    Examples:
      | rule_id                        |
      | PRICE_OUTLIER                  |
      | CONTRACT_SPLITTING_PATTERN     |
      | REPEATED_SINGLE_SOURCE         |
      | SUPPLIER_CONCENTRATION         |
      | LOW_BID_COMPETITION            |
      | RESTRICTIVE_SPECIFICATION      |
      | CONTRACT_AMENDMENT_ESCALATION  |
      | YEAR_END_SPENDING_SPIKE        |
      | NEW_SUPPLIER_DEPENDENCE        |
      | SHARED_SUPPLIER_IDENTITY       |

  # scenario-id: AC-PROCUREMENT-DOMAIN-012
  Scenario: PROMOTE_TO_CASE는 case·link·task·receipt를 원자적으로 만든다
    Given exact explanation digest를 가진 NEW signal version 4가 있다
    When triager가 new-case target, investigation question, task owner, dueAt와 reason으로 PROMOTE_TO_CASE를 요청한다
    Then signal update, case, case-signal link, owned task, audit, outbox와 SignalTriageReceipt가 한 transaction에서 생성된다
    And receipt는 case ID/version, task ID/owner/dueAt와 decision digest를 포함한다
    And 어느 한 insert라도 실패하면 모든 effect가 0개이다

  # scenario-id: AC-PROCUREMENT-DOMAIN-013
  Scenario: LINK_TO_CASE는 stale case에 일부 link를 남기지 않는다
    Given exact explanation digest를 가진 signal과 existing case version 9가 있다
    When triager가 expected case version 9, task owner, dueAt와 reason으로 LINK_TO_CASE를 요청한다
    Then case link, owned task, decision, signal version, audit, outbox와 receipt가 원자적으로 저장된다
    When 같은 요청이 stale case version 8을 사용한다
    Then VERSION_CONFLICT가 반환되고 link, task, decision, audit-success와 outbox는 0개이다

  # scenario-id: AC-PROCUREMENT-DOMAIN-014
  Scenario: promote와 link에서 target·task·owner·due·reason 중 하나라도 빠지면 거부한다
    Given PROMOTE_TO_CASE 또는 LINK_TO_CASE decision detail이 있다
    When target, task, owner, dueAt, reason code 또는 reason 중 하나를 각각 제거해 schema를 검증한다
    Then 각 변형은 INVALID_PARAMETER이다
    And signal, case, link, task, audit-success, outbox와 receipt는 0개이다

  # scenario-id: AC-PROCUREMENT-DOMAIN-015
  Scenario: response request는 exact public claim revision과 evidence locator를 묶는다
    Given review snapshot에 public candidate claim revision 두 개가 있다
    And 각 claim에는 verified evidence revision과 source asset revision의 exact locator가 있다
    When editor가 ordered claims, questions, publication scope, subject와 dueAt으로 response request를 보낸다
    Then request scope는 claim ID/revision/digest와 evidence ID/version/digest/locator digest를 모두 저장한다
    And claim set, evidence locator set, question set, publication scope와 전체 scope digest가 재계산과 같다
    And delivery action과 receipt는 같은 scope digest를 가진다

  # scenario-id: AC-PROCUREMENT-DOMAIN-016
  Scenario: stale claim 또는 changed evidence locator는 response request를 만들지 않는다
    Given composer가 claim revision 3과 evidence locator digest A를 보여줬다
    And send 전에 claim revision 4가 생기거나 locator digest가 B로 바뀌었다
    When editor가 이전 scope digest로 response request를 보낸다
    Then VERSION_CONFLICT 또는 PRECONDITION_FAILED가 반환된다
    And response request, scope member, delivery proposal, audit-success, outbox와 receipt는 0개이다

  # scenario-id: AC-PROCUREMENT-DOMAIN-017
  Scenario: 같은 contract filter set은 입력 순서와 무관하게 같은 digest다
    Given 같은 agency IDs, supplier IDs, statuses와 methods를 다른 순서로 입력한 filter 두 개가 있다
    When ProcurementContractFilterV1 canonicalization을 적용한다
    Then 두 filter digest가 같다
    And duplicate, unknown enum, signedFrom 이후 signedTo와 amountMin 초과 amountMax는 INVALID_PARAMETER이다

  # scenario-id: AC-PROCUREMENT-DOMAIN-018
  Scenario: list와 export는 같은 query snapshot digest를 사용한다
    Given listContracts가 snapshot ID, filter digest, member count와 member set digest를 반환했다
    When 같은 export binding으로 downloadContracts와 createDatasetExport를 요청한다
    Then 두 export receipt의 snapshot ID, filter digest, member count와 member set digest가 list response와 같다
    And receipt에는 format, media type, byte length, content hash, rights digest와 expiry가 있다

  # scenario-id: AC-PROCUREMENT-DOMAIN-019
  Scenario: filter나 snapshot이 달라지면 현재 데이터로 조용히 다시 export하지 않는다
    Given 사용자가 본 query snapshot 뒤에 새 contract projection이 생겼다
    When changed filter digest, changed member set digest 또는 expired snapshot으로 export를 요청한다
    Then 요청은 typed conflict 또는 expiry error로 거부된다
    And export job, object, signed URL과 success receipt는 0개이다
    And 서버는 현재 projection으로 다른 row set을 자동 생성하지 않는다

  # scenario-id: AC-PROCUREMENT-DOMAIN-020
  Scenario: explicit contract delete는 tombstone과 correction impact만 추가한다
    Given 공개 revision이 참조하는 contract revision이 있다
    And 완결된 KONEPS delete-history run이 exact prior contract digest를 제공한다
    When delete record를 normalize한다
    Then DELETED contract tombstone revision이 prior digest에 연결된다
    And raw bytes, prior contract/amendment/evidence/snapshot/publication revision은 삭제되지 않는다
    And 공개 영향은 owner와 dueAt이 있는 correction review task로 전달된다
    But partial, interrupted, quota-limited 또는 page-absence run은 tombstone을 만들지 않는다
