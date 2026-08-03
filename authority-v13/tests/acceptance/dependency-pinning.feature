@hard-gate @final @supply-chain
Feature: Toolchain and dependency pinning are reproducible in the final source tree

  # scenario-id: AC-DEPENDENCY_PINNING-001
  Scenario: Rust toolchain is exactly pinned
    Given rust-toolchain.toml exists
    Then channel is 1.97.0
    And Cargo.lock is tracked

  # scenario-id: AC-DEPENDENCY_PINNING-002
  Scenario: PostgreSQL image is exactly pinned
    Given Compose and the technology baseline exist
    Then the image is postgres:18.4-bookworm
    And the release image lock contains an immutable digest

  # scenario-id: AC-DEPENDENCY_PINNING-003
  Scenario: Bun and core frontend tools are exactly pinned
    Given root package.json and bun.lock exist
    Then packageManager is bun@1.3.14
    And Svelte, SvelteKit, adapter, TypeScript, Biome and Hey API versions match the baseline

  # scenario-id: AC-DEPENDENCY_PINNING-004
  Scenario: SQLx runtime and TLS features use the 0.9 contract
    Given the Cargo workspace uses SQLx 0.9.0
    Then features include runtime-tokio and tls-rustls-ring-webpki
    And no deprecated combined runtime-tokio-rustls feature exists

  # scenario-id: AC-DEPENDENCY_PINNING-005
  Scenario: SQLx CLI upstream lock exception is narrowly compensated
    Given the development image installs SQLx CLI 0.9.0 without --locked
    Then the exact postgres,rustls feature set is fixed
    And the final evidence includes install log, resolved graph, SBOM, vulnerability scan and image digest
    And no other Cargo helper silently drops --locked

  # scenario-id: AC-DEPENDENCY_PINNING-006
  Scenario: Generated tool version drift is rejected
    Given generated OpenAPI and TypeScript clients are committed
    When generation is repeated with the locked tools
    Then the repository has no diff
    And output metadata identifies the locked generator version

  # scenario-id: AC-DEPENDENCY_PINNING-007
  Scenario: Clean bootstrap resolves the same dependency graph
    Given two clean network-allowed bootstrap environments
    When Cargo and Bun dependencies are installed from the lockfiles
    Then both environments resolve identical package checksums
    And all format, compile and test commands pass

  # scenario-id: AC-DEPENDENCY_PINNING-008
  Scenario: Unreviewed core dependency change is blocked
    Given a core dependency version or image digest changes
    When the final supply-chain gate runs
    Then an approved ADR and compatibility evidence are required

  # scenario-id: AC-DEPENDENCY_PINNING-009
  Scenario: Security and document-processing dependencies are exact direct pins
    Given the Cargo and runtime BOMs
    Then OIDC, ChaCha20-Poly1305, object storage, SMTP, OpenTelemetry, CSV, XML, XLSX, ZIP, PDF and malware-scanner dependencies have exact versions
    And Tesseract, Korean/English trained data and pdftoppm are pinned in the document-extractor image lock
    And first-party code invokes external OCR tools through safe child processes without FFI

