# 01. 제품 요구사항(PRD)

## 1. 목적과 범위

이 문서는 구린네의 사용자 요구, 기능 요구, 비기능 요구, 우선순위, 완료 조건을 정의한다. UX 세부는 `specs/ui`, 데이터 계약은 `docs/06-domain-model.md`와 `specs/schemas`, 공개 기준은 `docs/03-editorial-publication-policy.md`가 우선한다.

## 2. 제품 가설

공공계약 데이터는 이미 상당 부분 공개되어 있지만, 서로 다른 형식과 맥락 때문에 이상 패턴을 찾기 어렵다. 원문 provenance, 정규화, 결정적 규칙, 제한된 AI 조사, 사람 검토를 하나의 workflow로 묶으면 다음 가치가 생긴다.

- 사람의 조사 시간을 “문서 찾기”에서 “설명 검증”으로 이동
- 전국·수년 단위의 반복 패턴 발견
- 자극적 의혹 대신 계산과 반대가설 제공
- 정정과 소명을 구조화해 신뢰 축적

## 3. Persona와 핵심 Job

### P1 시민 독자

- 관심 지역/기관의 공개 계약을 검색하고 싶다.
- 왜 이상 신호가 생겼는지 한눈에 이해하고 싶다.
- 원본과 계산을 직접 확인하고 싶다.
- 사건이 정정되거나 공식 확인되면 알고 싶다.

### P2 기자·연구자

- 조건을 조합해 조사 후보를 좁히고 싶다.
- 비교군과 제외 사유를 export하고 싶다.
- 업체·기관의 시간 흐름과 계약 네트워크를 보고 싶다.
- rule version별 결과 차이를 재현하고 싶다.

### P3 조사자

- signal queue에서 명확한 이유와 data quality를 보고 triage하고 싶다.
- evidence, unknown, counter-hypothesis, next action을 분리하고 싶다.
- AI 조사 결과를 맹신하지 않고 citation 단위로 검증하고 싶다.

### P4 편집자·법률 검토자

- 공개에 필요한 check가 빠졌는지 자동으로 알고 싶다.
- 문장별 근거와 위험 표현을 검토하고 싶다.
- 승인·반려·정정 이력을 감사 가능하게 남기고 싶다.

### P5 기관·업체 응답자

- 어떤 계약과 문장이 문제인지 정확히 보고 싶다.
- 인증된 link로 소명과 자료를 제출하고 싶다.
- 내 소명이 어떻게 반영되었는지 알고 싶다.

### P6 데이터 운영자

- source 장애, schema drift, quota, parser failure를 추적하고 싶다.
- raw를 재수집하지 않고 replay하고 싶다.
- backfill과 live ingestion 간 중복을 방지하고 싶다.

## 4. End-to-end 사용자 여정

### 4.1 Public case 탐색

1. 사용자가 홈의 최근 공개 case를 본다.
2. 필터로 기관, 지역, 계약 유형, signal type, 날짜, 상태를 좁힌다.
3. case detail에서 핵심 계산과 “이 결과가 의미하지 않는 것”을 본다.
4. 비교 계약과 제외 사유를 펼친다.
5. 원본 source와 checksum, rule version을 확인한다.
6. 기관·업체 response와 correction history를 확인한다.
7. 알림 또는 API export를 선택한다.

### 4.2 Internal signal triage

1. detector가 `AnomalySignal`을 생성한다.
2. 중복·data quality·blocking condition 자동 검사.
3. triager가 dismiss, merge, open case 중 선택.
4. open case에는 owner, due date, risk flags, investigation plan이 생긴다.
5. investigator와 AI assistant가 evidence/counter-evidence를 추가.
6. claim draft는 citation verifier를 통과.
7. response 요청과 대기 기간.
8. editor와 필요한 경우 legal reviewer 승인.
9. publisher가 승인된 revision을 atomic하게 공개.

### 4.3 Correction

1. 오류 신고 또는 내부 발견.
2. public page에 “검토 중” banner를 설정할 수 있다.
3. 원본과 계산 영향 범위를 조사.
4. 수정 문장과 reason code, affected claims를 기록.
5. 필요한 승인 후 새 revision 공개.
6. 이전 revision은 접근 가능하되 current 아님을 표시.
7. 중대한 경우 retraction 상태와 설명을 공개.

## 5. 기능 요구사항

### FR-001 Source registry

시스템은 source owner, access type, dataset ID, URL, quota, 이용조건, expected schema fingerprint, freshness, parser version, allowlist status를 관리해야 한다.

**Acceptance**
- 승인되지 않은 source는 scheduler에 활성화할 수 없다.
- 이용조건 검토일과 다음 재검토일이 없다면 `ACTIVE`가 될 수 없다.

### FR-002 Immutable raw ingestion

- fetch 요청/응답 metadata와 원본 body를 저장한다.
- SHA-256, byte size, MIME, retrieval time, HTTP metadata를 기록한다.
- 동일 source remote version/hash는 중복 raw object를 만들지 않는다.
- parser 변경 시 raw replay가 가능하다.

### FR-003 Parsing and field provenance

- source-specific parser는 canonical draft를 출력한다.
- 핵심 field마다 원본 JSONPath/XPath/HTML selector/PDF page region을 기록한다.
- required field 누락과 schema drift는 success로 숨기지 않는다.

### FR-004 Normalization

- money, currency, VAT basis, quantity, unit, date/time, contract method, category를 표준화한다.
- raw와 normalized 값을 모두 보존한다.
- 손실 변환은 confidence와 reason을 기록한다.
- bundle이 분해되지 않으면 `bundle_status=UNKNOWN`이다.

### FR-005 Entity resolution

- 공식 식별자 exact match가 우선이다.
- 이름·주소 fuzzy match는 candidate를 만들 뿐 자동 merge하지 않는다.
- merge/split은 audit event와 영향 재계산을 발생시킨다.
- public view는 ambiguity를 숨기지 않고 식별되지 않은 공급자로 표시할 수 있다.

### FR-006 Rule registry and execution

- 규칙은 immutable version, parameters, code commit, required fields, suppressions를 가진다.
- RuleRun은 input set과 output을 기록한다.
- 동일 입력에 결정적 결과를 보장한다.
- 규칙 비활성화는 과거 결과를 삭제하지 않는다.

### FR-007 Anomaly signal queue

- signal reason, raw metric, cohort, data quality, blocking conditions를 표시한다.
- 동일 계약·규칙·버전의 중복 signal을 막는다.
- priority는 영향 규모, evidence coverage, novelty, age로 정하되 정치·결제 정보는 금지한다.

### FR-008 Case management

- 여러 signal을 한 case로 묶을 수 있다.
- owner, watchers, due dates, risk flags, state version을 관리한다.
- 모든 transition은 허용 상태, 역할, guard를 검사한다.
- case duplicate/merge에도 provenance가 유지된다.

### FR-009 Evidence management

- evidence는 source, excerpt/field, supports/contradicts/neutral stance, verification status를 갖는다.
- AI summary와 원본 evidence를 구분한다.
- deleted upstream source는 checksum과 보존 정책을 표시한다.
- public 사용 여부와 redaction status를 관리한다.

### FR-010 Comparison explorer

- cohort inclusion criteria와 각 비교 항목을 보여준다.
- unit/VAT/spec/date/bundle adjustment를 표시한다.
- excluded observation과 reason을 숨기지 않는다.
- median, quartile, ratio 계산 JSON을 export한다.

### FR-011 AI investigation assistance

- schema-constrained output만 받는다.
- 사용한 evidence IDs, prompt/model/version, cost를 기록한다.
- fabricated reference를 reject한다.
- human이 accept/reject한 suggestion feedback을 보존한다.
- LLM failure가 case data를 손상시키지 않는다.

### FR-012 Right of reply

- verified contact 또는 공식 channel로 response request를 보낸다.
- 요청 내용, claims, deadline, delivery attempt를 기록한다.
- tokenized submission link는 만료·1회성·rate limit을 갖는다.
- 첨부는 검사 전 evidence가 아니다.
- response는 원문 보존, 요약 승인, public redaction을 분리한다.

### FR-013 Editorial review

- claim별 factuality, wording, evidence sufficiency, privacy, license, response status를 검토한다.
- reviewer는 자기 작성 claim을 단독 승인할 수 없다.
- high-risk flags는 legal approval을 요구한다.
- 반려 사유와 재검토 이력을 저장한다.

### FR-014 Publication

- current case snapshot에서 immutable revision을 만든다.
- 승인 후 승인된 exact content hash만 게시한다.
- public projection build가 실패하면 상태를 published로 확정하지 않는다.
- sitemap/feed/cache purge가 idempotent하다.

### FR-015 Correction and retraction

- affected claim, error type, discovery source, impact, corrected text를 기록한다.
- current revision pointer만 변경하고 과거 revision을 유지한다.
- material correction은 feed와 subscriber notification을 생성한다.

### FR-016 Public search and pages

- case, agency, supplier, contract, signal type, status, date 검색.
- 검색 결과는 publication만 반환한다.
- 각 page는 data freshness, coverage, limitations를 표시한다.
- 개인정보와 내부 score는 노출하지 않는다.

### FR-017 Methodology transparency

- active/retired rule versions, thresholds, required fields, known failure modes 공개.
- rule 변경 전후 영향 summary 제공.
- source coverage와 downtime 공개.

### FR-018 API/export

- public read API는 cursor pagination, stable IDs, rate limit, ETag를 제공.
- bulk export는 라이선스·개인정보·비용에 따라 별도 job.
- internal endpoints는 public origin에서 접근할 수 없다.

### FR-019 Notifications

- case publication, material correction, official confirmation, source methodology change 알림.
- 조사 중 private 상태는 외부 구독자에게 보내지 않는다.
- unsubscribe와 frequency control을 제공한다.

### FR-020 Funding/conflict transparency

- 주요 후원자·기관 고객 범주, editorial firewall, conflict disclosure를 public page에 게시.
- 개별 사건에 이해상충이 있으면 case에 표시한다.

## 6. 비기능 요구사항

### NFR-001 Security

- OWASP ASVS 수준의 web/control security를 목표로 한다.
- least privilege, MFA/OIDC, CSP, secure cookies, audit trail.
- SSRF, parser bomb, prompt injection, attachment malware 통제.

### NFR-002 Privacy

- data minimization과 목적 제한.
- public source라는 이유만으로 연락처·주민 식별자를 재공개하지 않음.
- 제보 기능 전 별도 DPIA와 architecture approval 필요.

### NFR-003 Availability

Pilot target:
- public read: monthly 99.5%
- control plane: monthly 99.0%
- planned maintenance 제외 기준은 운영 문서에 명시

### NFR-004 Freshness

source capability에 따라 class를 나눈다.

- near-real-time API: P95 source publication to ingestion < 2h
- daily source: P95 < 24h
- monthly/periodic source: source published + 3 business days

UI에는 실제 timestamp를 표시하며 “실시간” 마케팅 문구를 기본 금지한다.

### NFR-005 Performance

Pilot design targets:
- public API cached read P95 < 400ms
- uncached search P95 < 1.5s
- case page LCP < 2.5s on representative mobile
- review queue P95 < 1.5s for 50k open signals
- raw ingestion sustained 10 requests/sec per connector within quota

### NFR-006 Scale envelope

초기 설계는 다음을 migration 없이 수용한다.

- 20 million source documents metadata
- 100 million normalized line items
- 5 million signals
- 100k cases
- 1 million publication revisions/evidence links

실제 partition/search 도입은 측정 후 한다.

### NFR-007 Accessibility

- WCAG 2.2 AA
- keyboard-only, focus visibility, semantic headings, accessible charts/table alternatives
- 색상만으로 상태 구분 금지
- Korean screen-reader labels

### NFR-008 Observability

- structured logs, metrics, traces, audit events
- source freshness, queue age, drift, parse failure, rule yield, cost, publication gate denial
- alert에는 실제 PII/문서 본문을 넣지 않는다.

### NFR-009 Cost control

- environment/day/month/case/provider budget
- automatic queue pause and explicit override approval
- prompt/result caching only when privacy and semantic key safe
- high-cost model은 escalation 조건 충족 시만

### NFR-010 Portability and replay

- raw object와 DB backup에서 핵심 state 복구
- provider-neutral model gateway
- source connector replay tests
- generated contracts; vendor-specific feature가 domain에 침투하지 않음

### NFR-011 Internationalization

Korean first. 식별자·API enum은 English. 향후 English 설명을 추가할 수 있으나 Korean publication이 canonical이며 번역은 별 revision metadata를 가진다.

### NFR-012 Auditability

- 누가 언제 무엇을 보고 승인했는지 기록
- audit log 삭제/수정 제한
- high-risk actions에 reason code 필수
- admin도 자기 audit trail을 지울 수 없음

## 7. 공개 위험 분류

| Risk | 예 | 추가 요구 |
|---|---|---|
| LOW | 기관 단위 집계, 비식별 통계 | editor 1 + automated checks |
| MEDIUM | 업체 실명 계약 단가 이상 | independent editor 2, response window |
| HIGH | 개인 실명, 담합/형사 암시, 선거, 안보 | legal review + executive approval |
| PROHIBITED | 제보자 신원, 비공개 안보, 근거 없는 범죄 단정 | 공개 불가 |

상세 기준은 editorial policy가 우선한다.

## 8. 제품 분석 이벤트

사용자 분석은 최소화한다. 다음 privacy-preserving event만 허용한다.

- page viewed by route category, no full query PII
- search performed with coarse filter metadata
- evidence expanded
- methodology opened
- correction history opened
- export requested
- notification subscribed/unsubscribed

광고 추적 pixel, fingerprinting, third-party behavioral profiling은 기본 금지다.

## 9. MVP가 아닌 첫 완결 릴리스 정의

최종 release는 합성 개발 모드와 운영 connector, 세 API, 세 SSR 앱, 조사·소명·공개·정정·운영 기능을 동시에 포함한다. 완료에는 다음이 모두 필요하다.

- 실제 source 1개 이상 안정적 ingestion
- provenance와 rule replay
- internal triage/investigation/editorial console
- right-of-reply workflow
- immutable public revisions/corrections
- public case/search/methodology/funding pages
- security/privacy/legal launch review
- backup restore와 incident drill

단순히 크롤러와 AI 요약 페이지를 띄운 것은 구린네의 첫 릴리스가 아니다.

## 10. 수용 기준 요약

모든 세부 acceptance는 `tests/acceptance`에 있다. 다음은 release blocker다.

1. human approval 없이 공개 불가
2. claim without evidence 불가
3. data unit/bundle/VAT ambiguity가 있으면 price claim publish 불가
4. entity ambiguity가 있으면 식별 가능한 대상 claim publish 불가
5. prompt injection을 명령으로 처리하지 않음
6. raw replay와 deterministic rule result
7. duplicate fetch/command가 duplicate state를 만들지 않음
8. schema drift quarantine
9. correction immutable history
10. cost cap and kill switch
11. response rights and deadline
12. public/private data separation

## v2 기술 비기능 요구사항

다음은 제품 요구사항의 일부이며 구현 편의로 축소할 수 없다.

1. Public API와 Control API는 별도 Rust/Actix binary, DB role, OpenAPI, TypeScript client, deployment여야 한다.
2. API·worker·scheduler·수집·정규화·탐지의 production runtime은 Rust여야 한다.
3. 모든 PostgreSQL 접근은 SQLx를 사용하고 PostgreSQL 18.4에서 migration/query를 검증해야 한다.
4. HTTP 운영 계약은 Rust source에서 생성한 separate OpenAPI JSON이어야 한다.
5. SvelteKit은 generated client를 사용해야 하며 handwritten parallel API DTO를 만들면 안 된다.
6. Public Web과 Review Console은 Bun 기반 SSR이어야 하며 Control credential은 browser에 노출되지 않아야 한다.
7. DB-only Docker와 full-container 개발 모드를 모두 제공해야 한다.
8. exact toolchain/package/image와 lock/digest로 재현 가능해야 한다.
9. SQLx metadata, OpenAPI, TypeScript client는 clean regeneration drift가 0이어야 한다.
10. 모든 long-running process는 health/readiness, tracing, bounded concurrency, graceful shutdown을 제공해야 한다.
11. Development는 synthetic adapter를 기본 사용하고 production은 preflight를 통과한 live adapter를 사용하지만 DB/API/codegen/SSR/container 경로는 동일한 실제 구현이어야 한다.
12. Production Python, `axum`, API startup migration, combined public/control/submission client, `latest` image는 금지한다.
