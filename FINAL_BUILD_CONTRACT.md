# Final Build Contract v13.0.0

## 결과물 정의

최종 결과물은 문서화된 domain·secret·OIDC·메일·object storage·공공데이터 설정을 주입하고 migration을 실행하면 서비스할 수 있는 완전한 애플리케이션이다.

Development/test는 외부 key 없이 synthetic adapter로 같은 domain/application path를 실행한다. Production은 adapter와 설정만 달라지며 별도의 임시 구현 branch를 두지 않는다.

## 권위와 명세 트리

활성 명세는 루트 `specs/` 단일 트리다. Git tag `authority-v13-frozen`은 불변
v13 원본과 base provenance를 검증하는 기준이며 현재 `specs/`를 대체하는
두 번째 명세 트리가 아니다. 루트 Manifest 파일은 권위 또는 검증 입력이 아니다.

## 완성 수량

- Public 35 + Response 8 + Internal 52 = **95 화면**
- Frozen base Public 43 + Submission 34 + Control 134 + Browser Identity 6 = **217 외부 operation**
- Addendum HTTP 54 = external 51 (Public 1 + Submission 8 + Control 42) + `PRIVATE_IDENTITY_API` supplier command 3이며 두 집합은 disjoint다.
- Final Public 44 + Submission 42 + Control 176 + Browser Identity 6 = **268 외부 operation**
- Final external은 **123 query**, **145 command**이며 command는 HTTP non-GET write 142 + protocol GET command 3이다.
- All-scope HTTP는 final external 268 + `PRIVATE_IDENTITY_API` 3의 disjoint union인 **271 operation**이며 **123 query**, **148 command**, HTTP non-GET write 145다. 별도의 기존 Internal Identity Service contract는 **9 operation**이다.
- All-scope HTTP Persistence mapping 271 (base 217 + disjoint addendum 54), optimistic-concurrency contract 66
- PostgreSQL **41 runtime migration** (24 base + 17 post-base, owner-declared 15), **309 active table**; frozen v13 first-party function/service-role baseline 72/13
- Agent 5, read-only tool 9, deterministic evaluation 50
- Connector 8, upstream operation 56
- Detection rule 15, concrete oracle evaluation 450
- Cargo member 34, Bun workspace 9, runtime service 18 (backend 15 + frontend 3), Compose service 21, deployment image 18
- Acceptance feature 35, scenario 271

## 상용·후원 경계

- 공개 사실·근거·정정 이력·소명권·기본 구독·합리적 public API/export는 무료로 계속 제공하며 후원·계약·청구 상태가 이를 제한하지 않는다.
- B2B Evidence Workspace가 제공하는 수금 방식은 서면계약·외부 전자세금계산서·계좌이체뿐이며 self-service checkout과 commercial payment API는 없다. 이미 외부에서 완료된 PG 정산은 exact invoice에 결합된 서명 typed `PG_SETTLEMENT_IMPORT` 회계 증거로만 수용하며, live PG·카드 결제·entitlement·후원→invoice 경로를 만들지 않는다.
- 후원은 SKU·고객계약·청구·entitlement와 무관한 **TEST_MODE_ONLY** 재원 경계다. live PG/ASP를 호출하지 않으며 운영 tier 권위가 없으면 `UNAVAILABLE`이다. 가격·tier·결제 성공을 발명하지 않는다.
- `PUB-035`는 기존 public-web의 `/donate` 화면이고, `PUB-023`은 승인된 공개 재원 revision을 내려받는 public operation 1개를 갖는다.

## 필수 불변식

- AI와 규칙 엔진은 비리·범죄를 확정하지 않는다.
- 사람 승인 없는 publication은 DB·API 양쪽에서 불가능하다.
- 모든 공개 사실 claim은 revision-fixed Evidence ID를 갖는다.
- 무응답을 인정으로 표현하지 않는다.
- 정정·철회는 과거 revision을 수정하지 않는다.
- Public API는 `public` projection만 읽는다.
- Submission row는 token/session RLS를 통과한다.
- Audit, parsed record, review snapshot/decision, publication revision은 append-only 또는 immutable이다.
- SourceDocument·RuleRun은 허용된 lifecycle transition만 가능하다.
- 모든 외부 egress는 allowlisted gateway를 통과한다.
- first-party Rust의 `unsafe`는 0건이다.
- Control API는 browser cookie, browser CSRF와 raw step-up authorization을 받지 않는다.
- Actor Assertion은 exact method/path/query/body/content type/operation/capability/Idempotency-Key에 결합된다.

## 고위험 command retry

1. BFF가 typed action descriptor에서 canonical ActionAuthorizationContext를 구성한다.
2. BFF가 cryptographically random Idempotency-Key를 생성한다.
3. Step-up transaction cookie는 raw Idempotency-Key와 action digest를 encrypted envelope로 보존한다.
4. Callback은 5분·최대 3회 issue 가능한 bounded authorization을 만든다.
5. 각 Control attempt는 fresh Actor Assertion JTI를 받으며 동일 Idempotency-Key와 exact request bytes를 사용한다.
6. Terminal receipt 후 authorization을 닫고, 미종료 grant는 만료된다.

## 외부 입력만 남는 항목

- 공개·내부·소명 domain
- 서비스별 PostgreSQL credential
- session/field-encryption/token-HMAC/audit-chain/assertion key
- OIDC issuer/client
- SMTP credential
- S3-compatible object store
- data.go.kr/Open DART 등 source key 또는 공식 manifest URL
- 선택적 AI provider key
- OTLP/Sentry endpoint

정확한 이름과 누락 시 동작은 `specs/config/secret-and-key-catalog.yaml`이 권위다.

## 완료 판정

`make verify-final`은 `verify-specs`, `verify-codegen`, Rust/SQLx, Bun/UI, runtime,
container/recovery 검증을 하나의 종속성 체인으로 실행한다. `build-ui`는 Bun 검증과
E2E/visual test가 공유하는 단일 UI build 경계다.

- `verify-specs`: 현재 `specs/`, frozen tag 핀, migration, acceptance source/design 계약
- `verify-codegen`: OpenAPI/client, response, acceptance registry, UI registry 결정성
- `build-ui`: SvelteKit SSR UI build

`make verify-final`의 hard gate는 다음을 모두 통과해야 한다.

- format, lint, strict typecheck, first-party unsafe/panic/code-size gate
- Rust unit/integration/property test와 SQLx prepare
- PostgreSQL 18.4 clean migration·routine resolution·privilege/RLS·immutability·lifecycle·submission·CSRF·authorization runtime test
- OpenAPI/client deterministic regeneration
- Svelte SSR build, 95-route E2E·visual·accessibility
- Agent, Connector, Parser/OCR, Detection evaluation
- Docker network isolation, restart persistence, backup/restore
- security header, session, CSRF, assertion, IDOR, prompt-injection test

Sealed acceptance는 `make verify-acceptance`로 별도 실행하고 독립 evidence validation을
통과해야 한다. override가 없으면 Git이 무시하는 `artifacts/acceptance/`에
run-scoped evidence와 검증용 source bundle/extraction receipt를 생성한다.

`make source-archive`는 배포 archive를 `artifacts/`에 만든다. Manifest는 archive 내부에서만
생성·검증하며 루트 소스 트리의 권위 검증 근거로 사용하지 않는다.

하나라도 미검증이면 완료가 아니다.
