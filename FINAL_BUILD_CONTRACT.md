# Final Build Contract v13.0.0

## 결과물 정의

최종 결과물은 문서화된 domain·secret·OIDC·메일·object storage·공공데이터 설정을 주입하고 migration을 실행하면 서비스할 수 있는 완전한 애플리케이션이다.

Development/test는 외부 key 없이 synthetic adapter로 같은 domain/application path를 실행한다. Production은 adapter와 설정만 달라지며 별도의 임시 구현 branch를 두지 않는다.

## 권위와 명세 트리

활성 명세는 루트 `specs/` 단일 트리다. Git tag `authority-v13-frozen`은 불변
v13 원본과 base provenance를 검증하는 기준이며 현재 `specs/`를 대체하는
두 번째 명세 트리가 아니다. 루트 Manifest 파일은 권위 또는 검증 입력이 아니다.

## 완성 수량

- Public 34 + Response 8 + Internal 52 = **94 화면**
- Public 43 + Submission 34 + Control 134 + Browser Identity 6 = **217 외부 operation**
- Private Identity = **9 operation**
- **110 query**, **107 command**: HTTP non-GET write 104 + protocol GET command 3
- Persistence mapping 217, optimistic-concurrency contract 66
- PostgreSQL **24 migration, 107 active table, 72 active first-party function**, service/privilege role 13
- Agent 5, read-only tool 9, deterministic evaluation 50
- Connector 8, upstream operation 56
- Detection rule 15, concrete oracle evaluation 450
- Cargo member 32, Bun workspace 9, Compose service 20
- Acceptance feature 35, scenario 271

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
- Svelte SSR build, 94-route E2E·visual·accessibility
- Agent, Connector, Parser/OCR, Detection evaluation
- Docker network isolation, restart persistence, backup/restore
- security header, session, CSRF, assertion, IDOR, prompt-injection test

Sealed acceptance는 `make verify-acceptance`로 별도 실행하고 독립 evidence validation을
통과해야 한다. override가 없으면 Git이 무시하는 `artifacts/acceptance/`에
run-scoped evidence와 검증용 source bundle/extraction receipt를 생성한다.

`make source-archive`는 배포 archive를 `artifacts/`에 만든다. Manifest는 archive 내부에서만
생성·검증하며 루트 소스 트리의 권위 검증 근거로 사용하지 않는다.

하나라도 미검증이면 완료가 아니다.
