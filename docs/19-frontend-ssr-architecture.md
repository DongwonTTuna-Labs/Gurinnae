# 프런트엔드 SSR 아키텍처 — 세 개의 SvelteKit 제품 surface

## 1. 목적

구린네 프런트엔드는 하나의 디자인 시스템과 TypeScript/Bun toolchain을 공유하지만 서로 다른 신뢰 경계, 사용자 목표, 세션, API client를 가진 세 애플리케이션으로 배포한다.

| 앱 | 사용자 | 인증 | API | 핵심 책임 |
|---|---|---|---|---|
| `public-web` | 시민·기자·연구자 | 핵심 읽기 anonymous | Public, 제한된 Submission server-only | 검색·이해·검증·정정/구독 진입 |
| `review-console` | 조사·편집·법률·운영자 | OIDC+MFA+RBAC | Control server-only | triage·조사·review·publication·operations |
| `response-portal` | 소명 요청을 받은 기관·업체 | request token, 필요 시 step-up | Submission server-only | 요청 확인·답변·첨부·제출·receipt |

세 앱은 origin, cookie scope, CSP, cache, deploy, incident kill switch를 분리한다. Navigation이나 CSS를 공유한다는 이유로 auth/session 또는 generated client를 합치지 않는다.

## 2. 공통 toolchain

- TypeScript strict
- Svelte 5 / SvelteKit SSR
- Bun install, script, build, runtime
- `svelte-adapter-bun`
- Biome format/lint
- `svelte-check`
- Playwright E2E
- generated Fetch clients

Node runtime fallback은 승인된 ADR 없이는 금지한다. Browser API에 의존하는 component는 SSR-safe guard와 hydration test를 갖는다.

## 3. 화면 source of truth

프런트엔드 구현은 다음 순서로 해석한다.

1. `specs/ui/screen-catalog.yaml`
2. `specs/ui/screen-data-contracts.yaml`
3. `specs/ui/roles-and-permissions.yaml`
4. `specs/ui/page-archetypes.yaml`
5. `specs/ui/component-catalog.yaml`
6. `specs/ui/content-patterns.yaml`
7. `specs/ui/design-tokens.yaml`
8. 화면별 generated Markdown과 wireframe
9. prototype은 정보 위계 검증용 참고

Screen Markdown이나 final prototype이 YAML authority와 충돌하면 `screen-catalog.yaml`과 `screen-build-manifest.yaml`을 따른다. 계약 변경은 source YAML과 파생 문서를 함께 수정하고 validator를 통과해야 한다.

각 화면 구현 PR에는 screen ID, milestone, operationId, role/capability, state profile, analytics event, Playwright journey를 명시한다.

## 4. Public Web

### 4.1 목적

공개 사용자가 “누가 나쁜가”가 아니라 다음 질문에 답하도록 한다.

- 무엇이 관찰됐는가?
- 왜 조사 가치가 있었는가?
- 무엇이 아직 확인되지 않았는가?
- 당사자는 무엇이라고 답했는가?
- 어떤 원본·비교·방법론으로 재현할 수 있는가?
- 이후 설명·정정·철회가 있었는가?

### 4.2 데이터 흐름

```text
browser request
→ SvelteKit server load
→ generated public client
→ Public API
→ curated public projection
→ SSR HTML + typed hydration data
```

핵심 사건·정정·방법론 내용은 JavaScript 없이도 HTML에 있어야 한다. Client-side enhancement는 필터, evidence drawer, chart/table interaction에 사용한다.

Correction request와 subscription은 다음 경로다.

```text
browser form
→ same-origin SvelteKit server action
→ generated submission client
→ Submission API
→ intake receipt
```

브라우저가 Submission API base URL이나 service credential을 알 필요가 없다.

### 4.3 캐시·SEO

- 공개 revision URL은 안정적이다.
- current URL과 revision URL의 canonical 관계를 정의한다.
- 정정/철회 시 CDN purge와 cache version을 갱신한다.
- search/filter는 noindex 또는 canonical policy를 따른다.
- token, preview, intake route는 noindex/no-store다.
- stale source는 최신인 것처럼 캐시하지 않는다.

## 5. Review Console

### 5.1 BFF 경계

```text
browser
→ SvelteKit server action/load
→ session/CSRF/capability check
→ generated control client
→ Control API
```

Control bearer/refresh token은 browser JavaScript, localStorage, page data에 넣지 않는다. Server action은 사용자의 명시적 action을 command로 변환하며 UI 숨김이 authorization을 대체하지 않는다.

### 5.2 업무 중심 구조

Console은 DB table별 CRUD 앱이 아니다. 다음 task loop를 중심으로 한다.

```text
signal 이해
→ blocker/데이터 품질 검토
→ 사건 생성/연결/해소
→ evidence·unknown·hypothesis 구성
→ claim 작성
→ 소명 요청·제출 반영
→ snapshot review
→ publication/correction
→ audit/operations
```

Case workspace는 현재 task, blocking issue, next allowed action을 먼저 보여준다. Sidebar에 수십 개 entity menu를 나열하는 방식은 금지한다.

### 5.3 High-impact action

게시, 정정, 철회, rule activation, source pause/replay, role grant, kill switch에는 다음이 필요하다.

- exact target과 영향을 받는 범위
- current/expected version
- reason code와 설명
- 필수 재인증 또는 독립 승인
- idempotency key
- confirmation에서 consequence 명시
- 성공/실패 receipt와 audit ID

일반 확인 모달 “정말 하시겠습니까?”만으로 구현하지 않는다.

## 6. Response Portal

### 6.1 Token 처리

초기 magic URL은 SvelteKit server가 token을 검증한 뒤 짧은 수명의 HttpOnly/Secure/SameSite session으로 교환한다. 검증 후 canonical URL에서 token을 제거한다.

금지:

- localStorage/sessionStorage
- analytics payload
- referrer
- error/log body
- screenshot filename
- browser history에 token을 장기간 유지

### 6.2 사용자 흐름

```text
요청 유효성 확인
→ 요청 범위·기한·공개 예정 문장 확인
→ 답변 작성
→ 첨부 quarantine 상태 확인
→ 제출 전 전체 review
→ 제출
→ immutable receipt와 향후 절차
```

다른 request, 내부 case, investigator note를 탐색할 수 없다. Deadline extension이나 support는 별도 intake일 뿐 publication을 자동 중단·변경하지 않는다.

### 6.3 안전한 편집

- autosave는 명시적 상태와 마지막 저장 시각을 표시한다.
- 충돌 시 마지막 write로 덮어쓰지 않는다.
- attachment는 scan 전 다운로드/preview하지 않는다.
- 사용자가 무엇이 public에 인용될 수 있는지 제출 전에 설명한다.
- timeout/만료 시 작성 중 내용을 무단 전송하지 않는다.
- 제3자 analytics를 사용하지 않는다.

## 7. Shared UI와 분리 원칙

`packages/ui`는 시각·접근성 primitive와 content-neutral component만 제공한다.

공유 가능:

- typography/layout/token
- button/input/dialog/banner/table/pagination
- evidence reference renderer의 안전한 primitive
- status badge의 정의된 variant
- loading/error/empty state shell

공유 금지 또는 surface-specific wrapper 필요:

- auth/session
- API client factory
- publication command form
- response token handling
- internal note renderer
- public SEO/cache policy

Shared component가 lowest-common-denominator가 되어 public 문맥과 internal workflow를 흐리지 않게 한다.

## 8. 상태 모델

모든 data screen은 해당 profile에 따라 최소 다음을 고려한다.

```text
initial loading
refreshing
empty legitimate
empty because coverage unavailable
partial data
stale data
permission denied
not found without existence leak
validation error
optimistic version conflict
dependency outage
incident/kill switch
success receipt
```

Skeleton만 반복하지 않는다. 특히 “0건”은 청렴, 문제 없음, 응답 없음의 인정으로 해석되지 않도록 원인을 설명한다.

## 9. 반응형 전략

- Public 핵심 읽기는 320 CSS px부터 지원한다.
- 표는 의미 없는 가로 스크롤 대신 priority column, card/list 또는 accessible overflow를 선택한다.
- evidence와 unknown은 모바일에서도 접히지 않은 요약을 제공한다.
- Internal 복잡 작업은 compact read/review를 지원하되 위험한 bulk operation은 desktop-required 안내와 안전한 read-only fallback을 제공할 수 있다.
- Response Portal은 모바일 작성/첨부/검토를 완결할 수 있어야 한다.
- viewport가 작다는 이유로 필수 상태·기한·불확실성·정정 표시를 숨기지 않는다.

## 10. 접근성

- semantic heading/landmark
- skip link와 일관된 focus order
- keyboard-only critical journey
- visible focus
- 200% zoom/reflow
- form label/instruction/error association
- live region은 필요한 변경에만 사용
- dialog focus trap/restore
- table caption/header association
- 차트와 관계도에 동등한 표/텍스트
- 색만으로 상태를 표현하지 않음
- motion reduction
- 한국어 문구와 날짜·금액·단위의 명확한 발음/표현

자동 도구만으로 통과를 주장하지 않는다. 최종 검증에는 실제 usability walkthrough와 screen reader spot check를 포함한다.

## 11. Content와 analytics

Copy는 `content-patterns.yaml`의 상태·불확실성·소명·정정 패턴을 사용한다. 임의로 “충격”, “역대급”, “비리 확정” 같은 engagement 문구를 만들지 않는다.

Analytics는 allowlist event와 최소 속성만 수집한다. 다음은 금지한다.

- 검색어 원문
- 이메일
- response token
- response/evidence/free-text 내용
- internal case title/claim
- clipboard content
- 전체 URL query/path에 포함된 민감 식별자

Product success는 체류시간·클릭 수가 아니라 이해, 재현, 적절한 소명·정정, 업무 오류 감소로 측정한다.

## 12. 테스트

### Static/compile

- Biome
- `svelte-check`
- strict TypeScript
- generated client import boundary
- server-only module leakage
- route↔screen catalog parity
- analytics event allowlist

### Component

- keyboard/focus/error association
- state variants
- long Korean text/large numbers
- reduced motion/high zoom

### SSR/integration

- JavaScript 없는 핵심 public content
- session/cookie/header forwarding
- cache/no-store/noindex
- version conflict
- token exchange/removal
- graceful shutdown/stream abort

### Playwright critical journeys

1. 공개 사건의 사실·미확인·소명·근거·정정 이해
2. 검색에서 기관/업체/계약/사건 구분
3. signal triage→case→evidence/claim→snapshot→approval→publication
4. stale approval/자기승인/권한 거부
5. response request→draft→attachment state→review→receipt
6. correction/retraction이 기존 revision을 보존
7. source incident/freshness 상태
8. keyboard/compact viewport critical path

## 13. 완료 조건

화면은 “route가 뜬다”로 완료되지 않는다. 다음이 모두 있어야 한다.

- 승인된 screen ID와 milestone
- 모든 blocking operation READY
- 정확한 section hierarchy와 no-go 준수
- 모든 정의된 state 처리
- role/capability test
- SSR와 browser boundary proof
- accessibility·responsive test
- analytics privacy test
- Playwright journey
- 미검증 위험의 명시


## v12 assurance, legal hold, audit export and real parser closure

- Review Console BFF owns browser cookies and synchronizer CSRF.
- Identity API accepts only request-bound service assertions and issues request-bound actor assertions.
- Control API accepts only `X-Gurine-Actor-Assertion`; it never receives browser session or CSRF credentials.
- Assertion format and replay rules are authoritative in `specs/auth/assertion-contract.yaml`.
- Schema mapping concurrency is guarded by `ops.schema_drifts.version`; exact mapping proposals use `(schema_drift_id, mapping_version, mapping_digest)`.
- Queue and source concurrency use `queue_name` and `source_id`, respectively.
