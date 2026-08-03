@hard-gate @final @data @ops
Feature: 수집과 재처리는 중복 side effect 없이 복구 가능하다

  # scenario-id: AC-INGESTION_IDEMPOTENCY-001
  Scenario: 같은 원본을 두 번 수집한다
    Given source, remote identity, version, content hash가 같은 response가 있다
    When connector를 두 번 실행한다
    Then SourceDocument logical version은 1개다
    And normalized Contract는 1개다
    And 두 번째 실행은 duplicate observation을 기록하고 성공한다

  # scenario-id: AC-INGESTION_IDEMPOTENCY-002
  Scenario: 같은 idempotency key에 다른 content는 충돌이다
    Given idempotency key "source:record:v1"이 payload hash A로 처리됐다
    When 같은 key에 payload hash B를 제출한다
    Then mutation은 거부된다
    And idempotency conflict security event가 생성된다

  # scenario-id: AC-INGESTION_IDEMPOTENCY-003
  Scenario: page 저장 후 checkpoint 전 crash에서 복구한다
    Given page raw objects가 저장됐다
    And checkpoint commit 전에 worker가 종료됐다
    When job이 lease를 다시 얻어 재실행된다
    Then 같은 raw/records는 중복 생성되지 않는다
    And 성공한 뒤에만 checkpoint가 advance된다

  # scenario-id: AC-INGESTION_IDEMPOTENCY-004
  Scenario: raw replay는 네트워크 없이 동일 normalized output을 만든다
    Given raw objects와 parser version이 보존돼 있다
    When external network를 차단하고 replay한다
    Then normalized semantic output과 hash는 기존 결과와 같다

  # scenario-id: AC-INGESTION_IDEMPOTENCY-005
  Scenario: lease가 만료된 worker의 결과는 fencing으로 거부한다
    Given worker A의 lease token은 4이고 만료됐다
    And worker B가 token 5를 받았다
    When worker A가 late completion을 제출한다
    Then completion은 stale fence로 거부된다

  # scenario-id: AC-INGESTION_IDEMPOTENCY-006
  Scenario: Document extraction is provenance-preserving and sandboxed
    Given valid CSV, XML, XLSX, DOCX, HWPX, digital PDF and scanned PDF fixtures
    When the document extractor runs without network access
    Then output conforms to the extraction-result schema
    And every text block or cell has a page, cell, row-column, paragraph or XPath locator
    And scanned PDF uses the pinned OCR fallback

  # scenario-id: AC-INGESTION_IDEMPOTENCY-007
  Scenario: Malicious or excessive documents fail closed
    Given XML entity, ZIP traversal, ZIP bomb, truncated PDF, encrypted document, oversized page or timeout fixtures
    When extraction preflight or parsing runs
    Then the document is rejected with a typed code
    And no external network, host filesystem or unbounded child process is used


  # scenario-id: AC-INGESTION_IDEMPOTENCY-008
  Scenario: Every parser fixture has an exact golden extraction result
    Given all valid and rejected parser fixtures
    When the reference extractor runs with the pinned toolchain
    Then every fixture output exactly matches its checked-in extraction JSON
    And valid outputs preserve stable page, cell, paragraph or XPath provenance
    And rejected outputs preserve the exact typed rejection code

  # scenario-id: AC-INGESTION_IDEMPOTENCY-009
  Scenario: Legacy binary HWP is quarantined for trusted offline conversion
    Given a legacy OLE Compound File HWP document
    When extraction preflight detects its magic bytes
    Then it is rejected with BINARY_HWP_UNSUPPORTED_REQUIRES_TRUSTED_CONVERSION
    And original bytes and SHA-256 are preserved
    And no automatic external conversion or first-party FFI is attempted
