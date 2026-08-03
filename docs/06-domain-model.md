# 06. 도메인 모델과 증거 그래프

## 1. 설계 목표

1. 원본에서 공개 문장까지 추적 가능
2. source overwrite와 correction history 보존
3. 결정적 계산과 AI 제안을 구분
4. 업체·기관 식별 오류를 되돌릴 수 있음
5. public/private projection 분리
6. event/outbox와 optimistic concurrency 지원

모든 ID는 opaque UUID/ULID 계열이며 외부 source identifier와 분리한다. 예제 prefix는 설명용이다.

## 2. Logical schemas

### `raw`

외부에서 가져온 변경 불가 원본과 fetch metadata.

### `core`

정규화 기관·업체·계약·품목·가격·규칙·signal.

### `editorial`

case, evidence, claim, response, review, publication draft, correction.

### `ops`

jobs, leases, outbox, idempotency, source status, model cost, audit.

### `public`

승인된 publication과 sanitized read models. Public API DB role은 여기만 읽는다.

## 3. 원본·수집 엔터티

### Source

```text
id
source_key unique
owner_agency
access_type
status
base_domains[]
terms/license metadata
freshness class
parser current version
created_at/updated_at
```

### FetchAttempt

외부 request 1회의 관측.

```text
id, source_id
request_fingerprint
requested_at/completed_at
http status/error category
response headers sanitized
bytes, mime
retry number
credential version reference (secret 아님)
raw_object_id nullable
```

### RawObject

object storage 바이트.

```text
id
storage_key private
sha256 unique with source scope as policy
byte_size
mime_detected/mime_declared
compression metadata
malware_scan_status
created_at
legal_hold
```

### SourceDocument

source의 논리 문서/레코드 version.

```text
id
source_id
remote_record_id
remote_version/updated_at
raw_object_id
content_sha256
published_at/effective_at/retrieved_at
schema_fingerprint
status CURRENT/SUPERSEDED/DELETED_UPSTREAM/QUARANTINED
```

Unique 후보:

```text
(source_id, remote_record_id, content_sha256)
```

## 4. 파싱·provenance

### ParserRun

```text
id, source_document_id
parser_name/version
code_commit
started/completed
status
warnings/errors
output_hash
```

### FieldProvenance

정규화 field 하나가 원본 어디에서 왔는지.

```text
id
parser_run_id
entity_type/entity_id
field_name
source_locator_type JSON_PATH/XPATH/CSS/PDF_REGION/CELL/RANGE
source_locator
raw_value_redacted
raw_value_hash
transform_name/version
confidence
```

민감한 raw value는 hash와 private reference만 저장할 수 있다.

## 5. 기관·업체 식별

### Agency

```text
id
canonical_name_ko
agency_type
jurisdiction
parent_agency_id
active_from/to
public_slug
identity_status
```

### AgencyIdentifier

```text
agency_id
scheme (G2B_DEMAND_AGENCY_CODE, MOIS_CODE, ALIO_ID, etc.)
value
valid_from/to
source_document_id
verified_at
```

### Supplier

법인/사업자 수준. 사람과 동일시하지 않는다.

```text
id
canonical_name_ko
entity_type CORPORATION/SOLE_PROPRIETOR/OTHER/UNKNOWN
status
public_slug nullable
identity_status CANDIDATE/VERIFIED/AMBIGUOUS/RETIRED
```

### SupplierIdentifier

```text
supplier_id
scheme BUSINESS_REGISTRATION_NUMBER_HASH/CORPORATE_REGISTRY_CODE/DART_CORP_CODE/G2B_SUPPLIER_ID
value_encrypted_or_hashed
last4 nullable
validity
verification source
```

사업자번호 전체를 public schema에 복사하지 않는다.

### EntityAlias

상호 변경, 표기 변형. source와 valid period.

### IdentityCandidate

fuzzy match 후보.

```text
left record/right entity
features and scores
proposed_by RULE/AI/HUMAN
status PENDING/ACCEPTED/REJECTED
reviewer
```

AI score만으로 accepted merge 금지.

### EntityMergeEvent / SplitEvent

canonical entity 변경을 append-only로 기록하고 영향을 받은 contracts/signals/cases를 재계산한다.

## 6. 조달 엔터티

### ProcurementPlan

발주 계획.

### ProcurementRequest

조달 요청.

### ProcurementNotice

공고.

```text
id, source refs
notice_number/revision
agency_id
procurement_type
method
published/open/close dates
estimated_amount/base_amount
requirements structured + raw
restriction metadata
```

### BidderParticipation / Award

공개 범위 내 참여·낙찰.

### Contract

```text
id
contract_number/source keys
agency_id
supplier_id nullable/ambiguous ref
notice_id/award_id nullable
contract_type
method
signed_at/start/end
currency
original_amount_won
current_amount_won
vat_basis
status
source assertions
```

### ContractAmendment

```text
id, contract_id
sequence
amendment_type
signed_at
amount_before/after/delta
term_before/after
reason_raw/reason_category
source_document_id
```

### ContractLineItem

```text
id, contract_id
line_number
raw_description
normalized_category_id
manufacturer/model/variant nullable
quantity decimal-as-string
unit_code
unit_price_won nullable
total_price_won
vat_basis
bundle_status
specification_json
normalization_confidence
```

Quantity는 integer가 아닐 수 있으므로 decimal canonical string/NUMERIC을 사용한다. Money는 integer won.

### ItemCategory / UnitDefinition

category taxonomy version, unit conversion graph, incompatible unit rules.

## 7. 가격 관측·비교 모델

### PriceObservation

```text
id
source_type
source_document_id
item identity/spec
observed_at
currency
unit_price_won
quantity_break
vat_basis
shipping/installation/training/maintenance/warranty inclusion
availability
quality_tier
verification_status
```

### ComparisonCohort

```text
id
cohort_definition_version
subject_line_item_id
candidate observation IDs
included IDs
excluded IDs with reason
minimum comparables
constructed_at
input_hash
```

### PriceAdjustment

환율·VAT·unit·time adjustment. 조정은 원값을 덮어쓰지 않는다.

### DerivedMetric

```text
metric_type MEDIAN/RATIO/IQR/ROBUST_Z/SHARE/HHI/etc.
input_ids
algorithm/version
parameters
value and unit
result_hash
```

## 8. 규칙과 신호

### RuleDefinition

```text
rule_key
version
name
status DRAFT/ACTIVE/SHADOW/RETIRED
required_fields
parameters
blocking_conditions
public_methodology
code_commit
approved_by/at
```

Rule version은 immutable. parameter 변경도 새 version.

### RuleRun

```text
id, rule_definition_id
scope type/id
input_ids/input_hash
started/completed
status
metrics
result_hash
```

### AnomalySignal

```text
id
rule_run_id
subject type/id
signal_type
severity_internal
priority_internal
summary structured
blocking_conditions[]
data_quality
publishability NOT_ASSESSED/BLOCKED/ELIGIBLE_FOR_INVESTIGATION
status OPEN/DISMISSED/ATTACHED
created_at
```

`severity_internal`은 public corruption score가 아니다.

## 9. 조사·증거 모델

### InvestigationCase

```text
id
case_number
state/version
risk_level
owner
opened_at/closed_at
public_slug nullable
primary_subjects
conflict flags
```

### CaseSignal

case와 signal many-to-many.

### Hypothesis

```text
id, case_id
statement
kind PRIMARY/ALTERNATIVE/NULL
status OPEN/SUPPORTED/WEAKENED/REJECTED/UNRESOLVED
created_by actor/agent
```

### Evidence

```text
id, case_id
source_document_id nullable
source_locator/provenance refs
kind OFFICIAL_RECORD/PRICE_OBSERVATION/RESPONSE/CALCULATION/etc.
stance SUPPORTS/CONTRADICTS/CONTEXT/NEUTRAL
verification_status
summary
private_object_ref nullable
public_excerpt nullable
redaction_status
license_status
created_by
```

### EvidenceRelation

Evidence가 어떤 hypothesis/claim/metric을 지지·반박하는지.

### Claim

```text
id, case_id
claim_type FACT/INTERPRETATION/STATUS/LIMITATION
text_ko
structured_fact_json
risk_flags
status DRAFT/VERIFIED/REJECTED/PUBLISHED
version
```

ClaimEvidence:

```text
claim_id, evidence_id, relation SUPPORTS/QUALIFIES/CONTRADICTS
```

FACT claim은 최소 SUPPORTS 1개. Material claim은 정책상 복수 source가 필요할 수 있다.

### InvestigationAction

request document, verify price, resolve identity, contact response, legal review 등의 task.

## 10. AI 실행 모델

### ModelRun

```text
id
purpose
provider/model identifier
prompt_template_id/version/hash
input evidence IDs and redacted payload hash
output object reference/hash
structured_validation status
citation_validation status
policy_validation status
tokens/cost/currency
started/completed
human disposition ACCEPTED/PARTIAL/REJECTED/UNREVIEWED
```

전체 prompt/raw output은 privacy tier에 따라 private object store. Public에는 사용 모델을 설명할 수 있지만 내부 prompt injection defense를 과도하게 노출하지 않는다.

### AgentSuggestion

ModelRun의 구조화된 제안. 상태를 직접 변경하지 않는다.

## 11. 소명 모델

### ResponseParty

agency/supplier와 contact channel. 개인 연락처는 private encrypted field.

### ResponseRequest

claims shared, delivery, deadline, token hash, status.

### ResponseSubmission

original text/object, submitted_at, verification, malware status, privacy review.

### ResponseExcerpt

public에 사용할 승인된 excerpt 또는 summary, original mapping과 consent/legal basis.

## 12. 검토·공개 모델

### ReviewSnapshot

case의 claim/evidence/response/methodology/redaction을 canonical serialization하여 hash.

### ReviewDecision

reviewer, role, decision, conditions, snapshot hash, policy version, timestamps, revoked_at.

### Publication

stable public identity, current revision.

### PublicationRevision

immutable structured document.

### Correction

reason, severity, affected claim IDs, old/new revision, explanation, requester, reviewers.

### OfficialOutcome

감사·행정·수사·판결 상태와 primary source.

## 13. 운영 엔터티

### Job

```text
type, payload_ref, status
priority
attempts/max_attempts
available_at
lease_owner/fencing_token/lease_expires_at
idempotency_key
last_error_category
```

### OutboxEvent

transactional event envelope, published_at, attempts.

### IdempotencyRecord

scope/key/request_hash/response/status/expiry.

### AuditEvent

actor, action, target, before/after hashes, reason, request/trace, timestamp. append-only.

### PolicyDecision

publication/fetch/model/data egress policy engine 결과와 rule version.

### BudgetLedger

provider/environment/case/day/month 비용과 reservation/actual.

## 14. Provenance graph

Canonical path:

```text
RawObject
  -> SourceDocument
  -> ParserRun
  -> FieldProvenance
  -> Contract/LineItem
  -> ComparisonCohort + DerivedMetric
  -> RuleRun
  -> AnomalySignal
  -> InvestigationCase
  -> Evidence
  -> Claim
  -> ReviewSnapshot/Decision
  -> PublicationRevision
```

그래프 edge:

```text
EXTRACTED_FROM
NORMALIZED_FROM
DERIVED_FROM
INCLUDED_IN
EXCLUDED_FROM
GENERATED_BY
SUPPORTS
CONTRADICTS
QUALIFIES
APPROVED_AS
SUPERSEDES
CORRECTS
```

Public reproducibility bundle은 public-safe nodes/edges만 제공한다.

## 15. DB constraints 핵심

- contract amount >= 0; correction/credit는 explicit type
- currency ISO 4217; current v1 KRW only but field 유지
- content SHA-256 64 lowercase hex
- publication revision unique(publication_id, revision_number)
- one CURRENT revision per publication partial unique index
- ReviewDecision snapshot hash exact
- Claim FACT requires support는 service + deferred validation; publish gate에서 강제
- outbox event unique aggregate/version/event type where appropriate
- job fencing token monotonic
- public projection foreign keys는 approved revision only

## 16. Soft delete 정책

Core/evidence/publication은 일반 soft delete flag로 숨기지 않는다.

- source supersede
- entity retire/merge
- signal dismiss
- case archive
- publication retract/access restrict
- PII erasure는 field redaction tombstone과 audit

법률상 삭제가 필요하면 private payload를 cryptographic erase하고 metadata/audit tombstone을 남기는 절차를 사용한다.

## 17. API exposure 분류

| Entity | Public | Internal | Notes |
|---|---:|---:|---|
| SourceDocument metadata | 제한 | 예 | raw body private; public link/hash only |
| Agency | 예 | 예 | contact fields 제외 |
| Supplier | verified만 | 예 | identifiers masked |
| Contract | approved/source-safe | 예 | source license check |
| AnomalySignal | publication에 포함된 것만 | 예 | internal score 제외 |
| InvestigationCase | publication projection만 | 예 | notes private |
| Evidence | redacted approved subset | 예 | legal memo/private response 제외 |
| ModelRun | summary optional | 예 | prompts/private payload 제외 |
| ReviewDecision | role/count summary | 예 | personal info 최소화 |
| AuditEvent | 일부 transparency stats | 예 | raw audit private |

## 18. Schema evolution

- additive optional field 우선
- enum 추가는 consumers가 unknown 처리할 수 있도록 contract test
- breaking change는 versioned endpoint/schema
- historical publication revision은 당시 schema version으로 해석 가능해야 함
- migration이 과거 result hash를 바꾸면 안 됨

## v2 Rust/SQLx 구현 매핑

도메인 모델은 `crates/domain`에 기술 독립적으로 구현한다. Actix request/response와 SQLx row를 domain entity로 직접 사용하지 않는다.

```text
Domain type                 Rust ownership                  PostgreSQL ownership
SourceDocument              crates/domain                  raw.source_documents
FieldProvenance             crates/domain                  raw.field_provenance
Contract/LineItem           crates/domain                  core.contracts/core.contract_line_items
RuleRun/AnomalySignal       crates/domain+detection        core.rule_runs/core.anomaly_signals
InvestigationCase           crates/domain                  editorial.investigation_cases
Evidence/Claim              crates/domain                  editorial.evidence/editorial.claims
ReviewSnapshot/Decision     domain+publication-policy      editorial.review_snapshots/review_decisions
PublicationRevision         domain+publication-policy      editorial.publication_revisions
DurableJob/Outbox            crates/jobs                    ops.durable_jobs/ops.outbox_events
```

`crates/application`은 repository/transaction port를 정의하고 `crates/persistence-postgres`가 SQLx 구현을 제공한다. Public/Control/Submission API DTO는 `crates/api-contracts`의 별도 module이며 domain object를 직접 serialize하지 않는다.

Aggregate mutation은 expected version과 transaction을 요구한다. Human approval, review snapshot hash, publication revision reference는 DB FK만으로 충분하지 않으므로 application policy와 SQL transaction에서 함께 검증한다.
