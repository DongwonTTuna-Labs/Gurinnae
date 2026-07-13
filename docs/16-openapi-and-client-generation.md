# OpenAPI와 생성 TypeScript client — Public·Control·Submission 3면 계약

## 1. 목적

구린네의 HTTP 계약은 프런트엔드가 추측하거나 사람이 중복 작성하지 않는다. Rust request/response DTO와 Actix handler가 operational source of truth이고, Utoipa가 OpenAPI 3.1 JSON을 결정적으로 생성하며, 동일 JSON에서 TypeScript Fetch client를 생성한다.

이 규칙의 목적은 단순 편의가 아니다.

- 구현·문서·클라이언트 drift를 차단한다.
- 공개 읽기, 내부 command, 외부 제출을 서로 다른 trust boundary로 유지한다.
- 화면별 data requirement를 실제 operationId에 연결한다.
- 공개 bundle에 내부 route나 credential이 포함되는 일을 구조적으로 막는다.
- Codex가 임의 fetch wrapper·DTO·endpoint를 만들지 못하게 한다.

## 2. 세 개의 독립 계약

| 계약 | Rust service | 생성 JSON | 생성 package | 주 소비자 |
|---|---|---|---|---|
| Public | `services/public-api` | `specs/generated/public-api.openapi.json` | `packages/api-client-public` | Public Web SSR |
| Control | `services/control-api` | `specs/generated/control-api.openapi.json` | `packages/api-client-control` | Review Console server-only |
| Submission | `services/submission-api` | `specs/generated/submission-api.openapi.json` | `packages/api-client-submission` | Response Portal·Public Web server-only |

세 계약을 하나의 client로 병합하지 않는다. 개발자 참고용 combined documentation을 만들 수는 있지만 code generation, authorization, ingress 또는 browser distribution 입력으로 사용할 수 없다.

### 2.1 Public contract

- non-health operation은 GET/HEAD만 허용한다.
- `public` schema의 승인된 projection만 반환한다.
- unpublished case, internal actor, raw evidence object key, model output, response token을 포함하지 않는다.
- anonymous cache와 SEO가 가능한 응답/헤더를 명시한다.

### 2.2 Control contract

- OIDC/MFA/RBAC가 적용된 내부 operation만 포함한다.
- 모든 mutation은 actor context, expected version, idempotency key, audit 결과를 갖는다.
- response-party가 사용하는 token endpoint를 포함하지 않는다.
- 생성 client는 SvelteKit server-only module에서만 import한다.

### 2.3 Submission contract

- request token 또는 검증된 email session 범위의 외부 intake만 포함한다.
- response draft/submission, correction request, subscription 같은 limited intake를 처리한다.
- publication, approval, case transition을 직접 변경하는 operation은 금지한다.
- 응답은 요청자가 볼 수 있는 최소 scope만 반환한다.
- 생성 client는 Public Web/Response Portal의 server-only module에서만 import한다.

## 3. 설계 baseline과 operational 계약

다음 최종 OpenAPI 파일이 구현 요구사항이다.

```text
specs/api/public-api.design-baseline.openapi.yaml
specs/api/control-api.design-baseline.openapi.yaml
specs/api/submission-api.design-baseline.openapi.yaml
```

운영에서는 Rust에서 생성된 JSON이 operational HTTP contract다. `specs/api/*.openapi.yaml|json`은 최종 의미 계약이며 프런트엔드 client generation은 Rust 생성 JSON만 입력으로 사용한다.

변경 흐름:

```text
product screen/data requirement
→ application use case와 DTO 설계
→ Actix handler/Utoipa annotation
→ Rust contract tests
→ canonical OpenAPI JSON
→ compatibility/policy checks
→ generated TypeScript clients
→ SvelteKit compile/SSR/E2E
```

화면이 필요한 operation은 `specs/ui/screen-data-contracts.yaml`에 먼저 등록한다. `REQUIRED` operation이 실제 OpenAPI에 존재하고 검증될 때만 `READY`로 바꾼다. 화면 구현을 위해 임시 REST endpoint를 만들지 않는다.

## 4. Rust API contract 규칙

### 4.1 DTO 분리

`crates/api-contracts`는 최소 다음 module을 분리한다.

```text
public
control
submission
problem
pagination
common_safe
```

Domain entity를 직접 response로 serialize하지 않는다. `common_safe`에는 세 surface에 노출해도 안전한 값 객체만 둔다. Public DTO가 editorial/private type을 import할 수 없고 Submission DTO가 internal review state를 import할 수 없다.

### 4.2 Handler 등록

- 모든 external handler는 `utoipa-actix-web`가 추적할 수 있는 승인된 registration helper를 사용한다.
- 임의 `.route()` 등록은 architecture test가 실패시킨다.
- health/readiness를 포함한 모든 operation에 명시적 `operationId`를 둔다.
- path parameter, request body, response, error, security, tag를 선언한다.
- 실제 Actix route inventory와 OpenAPI inventory를 테스트로 비교한다.

### 4.3 Operation ID

Operation ID는 SDK의 공용 함수 이름이므로 rename도 breaking change다.

권장 규칙:

```text
getPublicCase
listPublicCases
createReviewDecision
publishCaseRevision
getResponseRequest
submitResponse
```

- 사람에게 의미가 있어야 한다.
- service 안에서 유일하고 세 계약 전체에서도 충돌하지 않아야 한다.
- handler 함수명 자동 추론만 믿지 않는다.
- 화면 catalog의 data requirement는 정확한 operationId를 참조한다.

### 4.4 오류

세 계약 모두 RFC 9457 계열 Problem Details 구조를 사용하고 다음을 일관되게 포함한다.

```text
type
title
status
detail(instance-safe)
instance
code
correlation_id
field_errors(optional)
current_version(optional)
retry_after(optional)
```

Public error는 private object 존재를 추론하게 하지 않는다. Submission error는 token 유효성의 세부 이유를 과도하게 드러내지 않는다. Control conflict는 현재 version과 reload/rebase UX에 필요한 안전한 metadata를 반환한다.

## 5. 생성 명령과 결정성

```bash
cargo xtask openapi generate
bun run api:generate
cargo xtask openapi check
bun run api:check
```

`cargo xtask openapi generate`는 DB, network, 현재 시각, 랜덤 ID 없이 세 JSON을 생성한다. Canonicalization은 key ordering, newline, number/string representation을 고정한다.

`bun run api:generate`는 exact-pinned `@hey-api/openapi-ts`와 세 config를 사용한다.

```text
hey-api.public.config.ts
hey-api.control.config.ts
hey-api.submission.config.ts
```

생성 결과는 commit하지만 직접 수정하지 않는다. 다음 clean-regeneration gate가 필수다.

```bash
cargo xtask openapi generate
bun run api:generate
git diff --exit-code -- \
  specs/generated \
  packages/api-client-public/src/generated \
  packages/api-client-control/src/generated \
  packages/api-client-submission/src/generated
```

## 6. Generated package와 handwritten wrapper

각 package 구조:

```text
src/generated/     generator 전용, 직접 수정 금지
src/index.ts       안전한 export
src/server.ts      server-only factory가 필요한 경우
src/policy.ts      timeout/header/error mapping
README.md          소비 경계
```

Handwritten wrapper는 다음만 담당한다.

- base URL을 server environment에서 주입
- correlation/request ID
- bounded timeout/abort
- safe retry policy
- typed Problem Details mapping
- session credential forwarding
- tracing metadata

API DTO를 다시 정의하거나 response field를 추측하지 않는다.

## 7. 프런트엔드 import 경계

### Public Web

- public client: `+page.server.ts`, `+layout.server.ts`, `+server.ts`에서 사용 가능
- submission client: correction/subscription server action에만 사용 가능
- control client: 모든 경로에서 금지

### Review Console

- control client: `src/lib/server/**`, server load/action/endpoint에서만 사용
- public client는 공개 preview 비교가 필요한 control-side server code에서만 명시적으로 사용 가능
- submission client 직접 호출 금지; intake는 Control API의 internal read model을 통해 본다

### Response Portal

- submission client: server-only
- public/control client: 금지
- raw request token을 browser storage, analytics, referrer, source map에 넣지 않는다

정적 import graph 검사와 production bundle 문자열 scan을 모두 수행한다. TypeScript path alias만으로 우회하지 못하게 실제 resolved graph를 검사한다.

## 8. Compatibility와 breaking change

다음은 breaking 후보다.

- operationId 변경/삭제
- path/method 변경
- required request field 추가
- response required field 삭제
- enum value 삭제 또는 의미 변경
- security requirement 변경
- pagination/cursor 의미 변경
- error code 변경

Breaking change는 migration plan, 모든 소비자 동시 변경, rollout/rollback 전략이 있는 ADR 또는 change note를 요구한다. Public API는 이미 indexed/cached/cited될 수 있으므로 URL과 revision 의미를 특히 안정적으로 유지한다.

## 9. 보안·개인정보 검사

각 spec/client에 대해 자동 검사한다.

- Public schema에 private/editorial/intake-only field 이름 없음
- Control spec에 external token path 없음
- Submission spec에 internal/publication command 없음
- example에 실명, 실제 기관 의혹, secret, token 없음
- auth scheme과 endpoint policy 일치
- file upload content type/size/error contract 명시
- no-store/no-referrer가 필요한 Submission response 표시
- internal base URL 또는 bearer token이 browser bundle에 없음

## 10. Product/API readiness gate

화면은 다음 모두 충족할 때만 구현 가능하다.

1. screen catalog에 존재한다.
2. blocking data requirement가 `READY`다.
3. READY operationId가 해당 surface OpenAPI에 존재한다.
4. generated client 함수가 strict TypeScript compile을 통과한다.
5. role/capability와 public/private/intake classification이 확정됐다.
6. loading/empty/partial/error/conflict 상태의 response contract가 있다.
7. analytics event가 allowlist에 있고 민감 payload가 없다.

API가 준비되지 않았는데 mock을 production route에 남기거나 UI에서 임의 필드를 조합하면 완료로 인정하지 않는다.

## 11. 검증

- Rust route↔OpenAPI inventory parity
- OpenAPI 3.1 parse와 모든 `$ref` 해석
- operationId global uniqueness
- 세 계약 policy lint
- Hey API 네 client generation
- strict TypeScript compile
- deterministic regeneration hash
- import graph와 browser bundle leakage
- screen data contract READY↔OpenAPI parity
- representative SSR load/action contract tests
- Playwright public/control/submission critical journeys

실패한 codegen을 generated file 수동 수정, `any`, typecheck exclusion, combined client로 우회하지 않는다.
