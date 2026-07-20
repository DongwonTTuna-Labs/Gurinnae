# 용어집

- **Anomaly / 이상 징후**: 데이터 규칙상 일반 패턴과 다른 관측. 위법·부패 판정이 아님.
- **Signal**: RuleRun이 생성한 조사 후보 레코드.
- **Case**: 사람이 조사하기로 수락한 signal 묶음과 workflow.
- **Claim**: 공개 여부를 검토하는 구체적 사실·해석 문장.
- **Evidence**: Claim/Hypothesis를 지지·반박·맥락화하는 검증 가능한 자료.
- **SourceDocument**: 공식 source에서 수집한 논리 문서/레코드 version.
- **RawObject**: 변경 없이 보존한 실제 bytes.
- **Provenance**: 원본 위치, 변환, 버전, 계산을 연결한 계보.
- **Field provenance**: 정규화 field가 원본 JSONPath/page/cell 어디에서 왔는지.
- **Cohort**: subject와 비교 가능한 관측치 집합.
- **Blocking condition**: 신호는 있어도 public claim을 막는 미확인 조건.
- **Suppression**: 비교 불가능/중복 등으로 signal 생성을 하지 않는 결정.
- **RuleVersion**: immutable 탐지 규칙과 parameter version.
- **RuleRun**: 특정 입력 세트에 규칙을 실행한 기록.
- **Data quality**: completeness/validity/consistency/timeliness/provenance 등 품질.
- **Entity resolution**: source record를 같은 기관/업체 canonical entity에 연결.
- **Identity candidate**: merge가 확정되지 않은 후보.
- **Right of reply / 소명권**: 공개 전 대상이 정확한 claim에 답할 기회.
- **ReviewSnapshot**: 승인 대상 claim/evidence/response/policy의 hash된 snapshot.
- **PublicationRevision**: 변경 불가능한 공개 version.
- **Correction**: 이전 revision의 오류·맥락 변경을 새 revision과 연결.
- **Retraction**: 핵심 공개를 더 이상 유지하지 않지만 이력은 보존하는 상태.
- **Official outcome**: 감사·행정·수사·판결의 정확한 공식 단계.
- **Public projection**: private/editorial data에서 승인된 필드만 복제한 read model.
- **Policy gate**: 게시 전 상태·증거·소명·privacy·license·승인을 검사하는 결정적 코드.
- **AgentSuggestion**: AI output으로, 상태 변경 권한이 없는 제안.
- **Prompt injection**: 문서 내용이 agent를 속여 정책/도구를 변경시키려는 공격.
- **Idempotency**: 같은 요청을 반복해도 부작용이 한 번만 발생하는 성질.
- **Optimistic concurrency**: expected version이 맞을 때만 aggregate 변경.
- **Lease/fencing**: job 중복 worker의 stale write를 막는 소유권 token.
- **Transactional outbox**: domain 변경과 event를 같은 DB transaction에 기록.
- **Schema drift**: 외부 source의 필드/타입/semantics가 바뀌는 현상.
- **Replay**: raw 저장본에서 network 없이 parser/rule을 다시 실행.
- **Legal hold**: 분쟁/조사 때문에 일반 deletion을 일시 중단.
- **Coverage**: 실제 전체 중 구린네가 관측한 기간·기관·계약·금액 범위.
- **Internal priority**: 조사 queue 운영 점수. public corruption score 아님.
- **Abstention**: evidence 부족 등으로 agent/rule이 결론을 내리지 않는 것.
- **Synthetic fixture**: 실제 대상이 없는 테스트용 합성 데이터.

## v3 기술·제품 용어

| 용어 | 정의 |
|---|---|
| Actix Web | Public/Control/Submission HTTP 서비스를 구현하는 Rust web framework. Domain layer에는 들어가지 않는다. |
| Tokio worker | HTTP framework와 분리된 Rust async background process. Durable job을 실행한다. |
| SQLx offline metadata | live DB 없이 query macro를 검증하기 위해 commit하는 `.sqlx/` metadata. Live PostgreSQL check와 함께 사용한다. |
| Public API | 공개 curated read model만 읽는 별도 Rust binary/API/DB role. |
| Control API | OIDC/RBAC와 idempotent command를 처리하는 제한된 Rust binary/API. |
| Submission API | 외부 소명·정정·구독 intake만 처리하며 publication을 변경하지 못하는 별도 Rust binary/API. |
| Final OpenAPI contract | 전체 route/operation 요구를 표현하는 승인된 OpenAPI YAML/JSON. 실제 Rust 생성물은 이 계약과 의미적으로 동등해야 한다. |
| Generated operational OpenAPI | Rust DTO/handler에서 결정적으로 생성하는 public/control/submission JSON. HTTP 계약과 TypeScript client generation의 운영 source of truth. |
| Generated API client | Generated OpenAPI를 입력으로 Hey API가 만드는 TypeScript Fetch SDK. 직접 수정하지 않는다. |
| BFF | Browser가 Control/Submission credential을 갖지 않도록 각 SvelteKit server가 중개하는 Backend for Frontend. |
| SSR | SvelteKit server가 초기 HTML을 렌더링하는 Server-Side Rendering. Public SEO와 no-JS baseline을 제공한다. |
| Fencing token | lease를 잃은 오래된 worker가 늦은 side effect를 기록하지 못하게 하는 단조 증가 또는 고유 권한 토큰. |
| Transactional outbox | domain mutation과 발행할 event를 같은 DB transaction에 기록하는 패턴. |
| Inbox deduplication | at-least-once event 중복을 consumer가 event ID로 제거하는 패턴. |
| One-shot migrator | API startup과 분리되어 migration만 실행하고 종료하는 배포/Compose job. |
| DB-only mode | PostgreSQL은 Docker, Rust/Bun application은 host에서 실행하는 빠른 개발 방식. |
| Full-container mode | PostgreSQL, migrator, APIs, workers, web을 모두 Compose로 실행하는 재현성 검증 방식. |
| Fitness test | 선택한 아키텍처가 시간이 지나도 경계를 지키는지 자동으로 검증하는 테스트. |
| Canonical generation | timestamp/random/order 차이 없이 같은 input/tool version에서 byte-stable artifact를 생성하는 과정. |
| Server-only import | Control client/secret code가 browser bundle에 들어가지 않도록 SvelteKit server module로 제한하는 규칙. |
| Specification tooling | 운영 앱이 아니라 이 명세 패키지의 schema, fixture, manifest를 검증하는 Python 도구. |
