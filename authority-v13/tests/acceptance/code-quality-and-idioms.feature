@hard-gate @final @code-quality
Feature: First-party code is safe, idiomatic and responsibility-focused

  # scenario-id: AC-CODE_QUALITY_AND_IDIOMS-001
  Scenario: First-party Rust forbids unsafe code at compile time
    Given every first-party Rust crate root
    Then it contains #![forbid(unsafe_code)]
    And workspace lints set unsafe_code to forbid
    And no first-party Rust source contains unsafe block, unsafe function, unsafe trait, unsafe impl or direct extern C

  # scenario-id: AC-CODE_QUALITY_AND_IDIOMS-002
  Scenario: Production Rust avoids panic-based control flow
    Given first-party production Rust source
    Then unwrap, expect, panic, todo, unimplemented and unreachable macros are absent
    And recoverable failures use typed Result values

  # scenario-id: AC-CODE_QUALITY_AND_IDIOMS-003
  Scenario: Actix handlers have one transport responsibility
    Given an HTTP handler
    Then it only parses transport input, obtains actor context, calls one application use case and maps the result
    And it contains no SQL, domain transition implementation or provider SDK call

  # scenario-id: AC-CODE_QUALITY_AND_IDIOMS-004
  Scenario: SvelteKit code uses Svelte-native data and mutation flows
    Given a Svelte route requiring server data or mutation
    Then data is loaded through server load functions
    And mutation uses a form action or server endpoint with the generated client
    And no React-hook emulation, manual DOM mutation or direct internal API browser fetch exists

  # scenario-id: AC-CODE_QUALITY_AND_IDIOMS-005
  Scenario: Files and functions remain bounded
    Given first-party source files and functions
    Then no unexplained hard line limit violation exists
    And a file does not mix route wiring, business rules, SQL and response mapping

  # scenario-id: AC-CODE_QUALITY_AND_IDIOMS-006
  Scenario: YAGNI prevents speculative frameworks
    Given the approved product contract
    Then no generic CRUD engine, runtime workflow DSL or speculative plugin framework is introduced
    And every new abstraction has at least two real implementations or a declared external-boundary test seam
