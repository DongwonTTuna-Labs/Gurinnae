@hard-gate @final @frontend
Feature: Bun 기반 SvelteKit SSR

  # scenario-id: AC-SVELTEKIT_SSR-001
  Scenario: public case는 production SSR로 렌더링된다
    Given production build의 public-web이 실행 중이다
    When fixture case URL을 JavaScript 비활성 client로 요청한다
    Then 사건 제목과 상태와 핵심 근거가 HTML에 있어야 한다

  # scenario-id: AC-SVELTEKIT_SSR-002
  Scenario: public server load는 generated public client를 사용한다
    Given public case route source가 있다
    Then handwritten endpoint DTO 또는 raw control fetch가 없어야 한다

  # scenario-id: AC-SVELTEKIT_SSR-003
  Scenario: review mutation은 server action을 통과한다
    Given reviewer가 publication form을 제출한다
    Then browser는 SvelteKit server action에 요청해야 한다
    And server action이 generated control client를 호출해야 한다

  # scenario-id: AC-SVELTEKIT_SSR-004
  Scenario: control token은 browser에 없다
    Given review-console production assets가 있다
    Then bearer token과 OIDC refresh token과 control internal URL이 없어야 한다

  # scenario-id: AC-SVELTEKIT_SSR-005
  Scenario: stale version conflict를 덮어쓰지 않는다
    Given 화면의 expected_version이 오래되었다
    When mutation을 제출한다
    Then 409 conflict를 사용자에게 표시해야 한다
    And 자동 재시도 또는 overwrite를 하지 않아야 한다

  # scenario-id: AC-SVELTEKIT_SSR-006
  Scenario: SSR cookie가 안전한 속성을 가진다
    Given review session이 생성된다
    Then cookie는 HttpOnly Secure SameSite 정책을 가져야 한다

  # scenario-id: AC-SVELTEKIT_SSR-007
  Scenario: 신뢰하지 않는 forwarded header를 사용하지 않는다
    Given direct client가 위조된 forwarded host와 proto를 보낸다
    Then trusted proxy 밖에서는 canonical origin 계산에 사용하지 않아야 한다

  # scenario-id: AC-SVELTEKIT_SSR-008
  Scenario: correction 상태는 접근 가능하게 표시된다
    Given 공개 사건에 correction revision이 있다
    When public case를 읽는다
    Then color만이 아닌 텍스트와 landmark로 correction을 알려야 한다

  # scenario-id: AC-SVELTEKIT_SSR-009
  Scenario: Bun production runtime은 graceful shutdown한다
    Given in-flight SSR request가 있다
    When SIGTERM을 보낸다
    Then readiness가 내려가고 bounded drain 후 process가 종료해야 한다

  # scenario-id: AC-SVELTEKIT_SSR-010
  Scenario: hydration mismatch가 없다
    Given fixture public/review critical routes가 있다
    When SSR 후 browser hydration을 수행한다
    Then hydration warning과 content mismatch가 없어야 한다

# scenario-id: AC-SVELTEKIT_SSR-011
Scenario: adapter peer range 밖의 TypeScript는 compatibility matrix로 검증된다
    Given svelte-adapter-bun 1.0.1과 TypeScript 5.9.3 exact pins가 있다
    When clean Bun install과 두 app의 check build runtime smoke를 수행한다
    Then 모든 단계가 성공해야 한다
    And package-manager warning과 override 유무가 evidence에 기록되어야 한다

  # scenario-id: AC-SVELTEKIT_SSR-012
  Scenario: Node fallback은 검출된다
    Given production SvelteKit image와 process evidence가 있다
    Then runtime executable은 Bun이어야 한다
    And node binary 또는 @sveltejs/adapter-node fallback을 사용하면 실패해야 한다
