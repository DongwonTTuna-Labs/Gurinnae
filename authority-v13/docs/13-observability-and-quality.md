# 13. 관측성, 데이터 품질, 평가 운영

## 1. 목표

시스템이 “동작한다”는 것은 HTTP 200이 아니라 다음을 의미한다.

- source가 실제로 최신인지
- parser가 의미를 보존했는지
- rule 결과가 재현되는지
- false positive가 어디서 생기는지
- agent suggestion이 근거를 지키는지
- publication gate가 우회되지 않는지
- 정정이 얼마나 빠른지

## 2. Telemetry 원칙

- trace ID가 fetch -> parse -> normalize -> rule -> case -> publication까지 연결
- 로그는 structured JSON
- metric label cardinality 제한; case/supplier ID를 label로 쓰지 않음
- PII와 문서 본문은 로그 금지
- audit log와 debug log 분리
- clock/timezone UTC, source original time 보존

## 3. 핵심 metrics

### Source

- `source_fetch_requests_total{source,status}`
- `source_fetch_lag_seconds`
- `source_records_total{new,updated,duplicate,quarantined}`
- `source_schema_drift_total`
- `source_checkpoint_age_seconds`
- `source_quota_remaining`

### Parser/normalization

- parse success/failure/warning
- required field missing rate
- unknown unit/category/method
- provenance coverage
- normalization confidence distribution
- replay result mismatch

### Identity

- exact matches
- candidates pending
- accepted/rejected
- merges/splits
- post-publication identity corrections (critical)

### Rules

- runs/signals/suppressions per version
- input cohort size
- metric distribution
- triage disposition
- time to triage
- recomputation changes

### Agents

- calls/tokens/cost/latency
- schema validity
- citation validity
- prompt injection flags
- acceptance disposition
- abstention

### Editorial

- queue age
- response delivery/latency
- review turnaround
- approval/rejection
- publication count by status, not “success”
- correction severity/time

### Public

- latency/error/cache
- evidence/methodology/correction engagement
- subscription/unsubscription
- privacy-preserving search patterns

## 4. Tracing spans

```text
source.window
  fetch.http
  raw.persist
  schema.fingerprint
  parse.run
  normalize.batch
  identity.resolve
  rule.run
  signal.persist
case.command
  policy.evaluate
  audit.persist
  outbox.persist
agent.invoke
  context.build
  provider.call
  output.validate
publication.command
  gate.evaluate
  projection.build
  assets.copy
  activate.current
```

Trace baggage에 secret/PII 금지.

## 5. Data quality dimensions

- Completeness
- Validity
- Consistency
- Uniqueness
- Timeliness
- Accuracy (sample/manual/external reconciliation)
- Provenance completeness
- Coverage

Source별 baseline과 alert threshold. “빈 데이터”가 정상인지 장애인지 달력/과거 pattern으로 구분.

## 6. Quality gates

### Ingestion gate

required ID/date/amount parse; hash; source status.

### Rule gate

required normalized fields, minimum data quality.

### Case gate

identity and source currentness.

### Publication gate

100% provenance, reproducibility, response/privacy/license/approval.

각 gate 실패는 reason enum과 remediation action.

## 7. Evaluation corpus management

- synthetic fixtures: deterministic CI
- recorded-redacted fixtures: connector realism, license reviewed
- historical labeled cases: restricted access, de-identification where needed
- adversarial cases: injection, unit ambiguity, entity collision

Gold label에는 annotator, guideline version, evidence, disagreement, adjudication 기록.

## 8. Eval splits

- development
- validation
- locked test
- temporal holdout
- source holdout
- category/agency type slices
- adversarial safety set

Threshold를 test set에 반복 맞추지 않는다.

## 9. Metrics and minimums

### Deterministic pipeline

- parse exactness critical fields >= 99.5% on approved connector corpus
- money/unit transformation exactness 100% on fixtures
- idempotency 100%
- replay output hash 100%

### Detection

Initial curated set targets:

- price rule precision >= 0.85 for `INVESTIGATE`
- recall >= 0.80 on designed gold leads
- blocker recall 1.00 for unit/bundle/VAT ambiguity
- unsafe publication eligibility false positive 0

실제 population 성능으로 오해하지 않고 confidence interval 표시.

### Agents

- valid JSON >= 99%
- evidence reference precision 100% after validator
- accepted suggestion usefulness >= 70% target
- prohibited action acceptance 0
- prompt injection success 0 on locked red-team

### Editorial/public

- claim-evidence coverage 100%
- high-risk dual approval 100%
- response policy compliance 100%
- correction history preservation 100%

## 10. Error taxonomy

```text
SOURCE_MISSING
SOURCE_INCONSISTENT
PARSER_FIELD_MAPPING
UNIT_NORMALIZATION
VAT_BUNDLE_CONTEXT
ENTITY_RESOLUTION
COHORT_SELECTION
RULE_THRESHOLD
AGENT_HALLUCINATION
AGENT_OVERCLAIM
EDITORIAL_WORDING
PUBLIC_PROJECTION
PRIVACY_REDACTION
LICENSE
OPERATIONS
```

Correction은 root cause와 preventive action을 연결한다.

## 11. Data lineage audit

주기적으로 publication sample을 선택해 reverse traversal:

- public claim
- evidence
- metric/rule
- normalized field
- parser/provenance
- raw hash/source

끊긴 edge 0. Tool로 machine-verifiable report 생성.

## 12. Rule monitoring

Concept drift indicators:

- cohort size shifts
- unknown category/unit
- signal rate sudden change
- triage acceptance decline
- source composition changes
- dismissal reason shift

Rule을 silent tuning하지 않고 shadow version으로 비교.

## 13. Model monitoring

Provider/model drift:

- pinned version metadata
- weekly small locked eval
- response format and citation changes
- cost/latency
- safety set

Regression threshold에서 agent feature pause. Core ingestion/publication remains.

## 14. Dashboards

- Executive trust dashboard: corrections, provenance, source coverage, cost
- Data operations: source/parser/drift
- Rule quality: yield/disposition/slices
- Agent quality/cost
- Editorial queue/SLA
- Security: auth, SSRF/parser, privilege, kill switches
- Public reliability

## 15. Alerts

Pager-worthy:

- publication gate bypass attempt/success
- private data in public projection detector
- wrong entity correction
- audit gap
- source credential compromise
- widespread schema drift with checkpoint advance
- cost hard cap bypass

Ticket/office hours:

- gradual category unknown increase
- queue age
- minor source lag
- model suggestion quality decline

## 16. Experimentation

A/B test는 public allegation wording을 자극적으로 최적화하는 데 사용하지 않는다. 허용:

- navigation/accessibility
- methodology comprehension
- correction visibility
- notification frequency

Editorial outcome·target selection은 product growth experiment 대상이 아니다.

## 17. Quality review cadence

- daily source/incident
- weekly rule/queue/cost
- monthly correction/root cause
- quarterly methodology/fairness/source/license
- semiannual external review
- annual security/legal/data governance

## v3 기술·제품 품질 대시보드

필수 build/runtime dimensions:

- service, binary version, Git SHA, migration version
- OpenAPI artifact hash, generated client input hash
- PostgreSQL server version, SQLx metadata revision
- container image digest
- Bun/SvelteKit build revision
- operationId/job type/source/rule version

Required alarms:

- public/control/submission route/spec mismatch
- generated artifact drift
- SQLx prepare drift
- public role privilege unexpectedly succeeds
- outbox/projection lag
- stale lease/fencing rejection spike
- Bun SSR readiness/hydration/error regression
- image digest mismatch

Quality gate 결과는 `make verify` 아래 명령과 exit code로 기록한다. Static package validation, Rust compile, DB integration, frontend typecheck, container smoke를 서로 대신했다고 주장하지 않는다.
