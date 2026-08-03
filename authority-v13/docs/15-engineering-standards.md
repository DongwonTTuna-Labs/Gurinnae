# 엔지니어링 표준

## 1. 목적

이 문서는 Rust·TypeScript·SQL·container 코드의 품질 기준과 공통 실패 처리 규칙을 정의한다. 프레임워크 스타일보다 제품 불변식, 명시적 타입, 재현 가능한 검증을 우선한다.

## 2. 공통 원칙

- 테스트 가능한 가장 작은 완결 수직 단위로 변경한다.
- public interface의 입력, 출력, 오류, side effect를 문서화한다.
- 상태·권한·정책을 문자열 비교와 UI convention에 맡기지 않는다.
- 시간·random·network·filesystem을 port로 주입해 결정적 테스트를 가능하게 한다.
- 예상 가능한 오류를 panic/exception으로 숨기지 않는다.
- 로그와 error detail에 secret/PII/raw 문서를 넣지 않는다.
- TODO로 publication/security gate를 우회하지 않는다.
- generated code와 handwritten code를 디렉터리에서 분리한다.

## 3. Rust

### 3.1 Toolchain

- exact `rust-toolchain.toml`
- edition 2024
- `Cargo.lock` commit
- workspace resolver 3
- `unsafe_code = "forbid"`를 가능한 crate에 적용
- clippy warnings를 CI error로 처리

### 3.2 Workspace lint

권장 root 설정:

```toml
[workspace.lints.rust]
unsafe_code = "forbid"
missing_debug_implementations = "warn"
unreachable_pub = "warn"

[workspace.lints.clippy]
all = { level = "deny", priority = -1 }
pedantic = { level = "warn", priority = -1 }
unwrap_used = "deny"
expect_used = "deny"
panic = "deny"
dbg_macro = "deny"
todo = "deny"
```

Build script/test helper에 필요한 예외는 좁은 scope와 이유를 기록한다.

### 3.3 오류

- domain/application error는 typed enum
- adapter error는 retryable/permanent/policy/conflict로 분류
- HTTP는 stable machine code가 있는 Problem Details
- DB SQLSTATE와 내부 query를 public detail에 노출하지 않음
- `anyhow`는 binary composition/diagnostic 경계에서만 제한적으로 사용

### 3.4 타입

- ID별 newtype
- Money는 currency + integer minor amount
- Ratio/statistics는 공개 precision과 internal precision을 명시
- timestamp는 UTC; source 표기와 timezone metadata 보존
- URL은 parse/allowlist 통과한 타입
- redacted secret wrapper는 Debug/Display로 값 노출 금지

### 3.5 Async

- blocking parse/CPU work는 `spawn_blocking` 또는 bounded pool
- unbounded task spawn/channel 금지
- cancellation과 graceful shutdown 지원
- timeout은 call site가 아닌 adapter policy에서 일관되게 설정
- DB transaction을 network call 동안 열어두지 않음

## 4. Actix Web

- app factory를 library에서 만들어 integration test 가능하게 함
- handler는 DTO validation → auth context → use case → response mapping
- middleware 순서는 request ID, tracing, body limit, auth, rate-limit, handler, error mapping으로 명시
- body limit은 operation별 또는 API default로 지정
- JSON content type/charset 정책 고정
- proxy header는 trusted proxy에서만 수용
- health와 readiness 분리
- CORS는 public API의 필요한 origin만; control API broad CORS 금지

## 5. SQL/SQLx

- migration은 forward-only additive 우선
- 모든 table에 명시적 PK, timestamps, 필요한 check/unique/FK
- cascade delete는 데이터 보존 정책과 일치할 때만
- dynamic identifier/table/column user input 금지
- query plan과 index 근거를 high-volume table migration에 기록
- transaction isolation 요구를 use case별 명시
- row-level security는 만능 방어가 아니라 role/grant와 함께 검토
- fixture seed와 migration을 혼합하지 않음

## 6. TypeScript/Svelte

- `strict: true`; `any` 기본 금지
- generated API type을 수동 재정의하지 않음
- `unknown`은 schema/guard로 좁힘
- server-only module에서 secret/control client 사용
- Svelte action/load return type과 form error shape를 명시
- accessibility warning을 무시하지 않음
- browser state를 authoritative domain state로 사용하지 않음
- mutation 성공 후 returned aggregate version을 반영
- optimistic UI는 irreversible/editorial command에 기본 금지

## 7. Biome와 formatting

Biome가 JS/TS/JSON/CSS/Svelte 지원 영역의 formatter/linter/import organizer다. `svelte-check`는 Svelte compiler와 type 진단이다. 같은 역할로 ESLint/Prettier를 기본 도입하지 않는다.

Generated directories는 formatter rewrite 대상에서 제외할 수 있으나 compile/typecheck에는 포함한다.

## 8. Testing pyramid

- domain property/unit: 가장 많음
- application use-case with ports
- SQLx repository/role/migration integration
- Actix API contract/integration
- code generation drift
- frontend component/server load/action
- Playwright critical journey
- Gherkin policy/architecture acceptance
- container smoke

Mock은 외부 boundary에 사용한다. DB semantics를 in-memory fake로 대체하여 PASS를 주장하지 않는다.

## 9. Review checklist

- 정책/상태 전이를 handler/UI에 복제했는가?
- public/private DTO와 DB role이 섞였는가?
- generated artifact를 직접 수정했는가?
- retry가 중복 side effect를 만들 수 있는가?
- 로그/metric cardinality/PII 문제가 있는가?
- migration이 이전 버전과 호환되는가?
- failure/recovery path가 테스트되었는가?
- acceptance 또는 eval 기준을 약화했는가?
