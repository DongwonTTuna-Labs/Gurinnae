# 07. 이상 징후 탐지 방법론

## 1. 원칙

탐지 엔진은 “비리를 맞히는 AI”가 아니다. 공개 데이터에서 설명이 필요한 패턴을 좁히는 **재현 가능한 lead generator**다.

- 규칙은 결정적 코드다.
- 모든 규칙은 versioned parameter와 input set을 기록한다.
- threshold는 불법 기준이 아니라 조사 우선순위 기준이다.
- 규칙마다 false-positive taxonomy와 blocking condition이 있다.
- LLM 분류는 후보를 만들 수 있지만 최종 cohort/metric은 검증된 structured field만 사용한다.
- 규칙 성능은 규칙별·기관유형별·품목군별로 측정한다.

## 2. 공통 처리 단계

```text
Eligibility
 -> Data quality checks
 -> Candidate generation
 -> Compatibility filtering
 -> Metric calculation
 -> Threshold evaluation
 -> Suppression/blocking
 -> Signal explanation
 -> Evaluation logging
```

### Eligibility

required fields, source freshness, entity identity, status/currentness.

### Compatibility

가격의 경우 category만 같아서는 부족하다. model/spec, unit, quantity, VAT, date, bundle, installation, warranty를 평가한다.

### Suppression vs blocking

- suppression: signal 자체를 만들지 않음(명백히 비교 불가능)
- blocking: internal signal은 만들지만 public candidate가 될 수 없음(핵심 맥락 미확인)

## 3. Data Quality Score

내부 score 0–100. public corruption score가 아니다.

구성 예:

- identity completeness 20
- money/quantity/unit 20
- VAT/bundle 15
- spec/model 20
- source freshness/version 10
- provenance completeness 15

가격 rule 기본 eligibility는 70 이상, publish candidate는 90 이상. 단, 숫자 임계값은 RuleVersion에 고정하고 eval로 조정한다.

## 4. 규칙 1 — `PRICE_OUTLIER_V1`

### 목적

비교 가능한 관측치 대비 단가가 현저히 높은 계약 line item을 찾는다.

### 필수 입력

- normalized category
- quantity and unit
- unit price or total/quantity derivation
- currency, VAT basis
- contract date
- bundle status
- minimum specification attributes

### Cohort filter

- same category taxonomy version
- compatible unit; exact 또는 승인된 conversion
- observation date ±365 days 기본
- VAT basis normalized
- currency KRW 또는 verified FX adjustment
- spec compatibility `EXACT` or `COMPATIBLE`
- bundle components comparable
- quantity band: subject의 0.25x–4x 기본, price break가 있으면 모델링

### Minimum

- independent comparable 8개 기본
- 동일 supplier observations가 cohort 40%를 넘으면 concentration warning
- source 2종 이상 권장; 전부 같은 계약 series이면 independence 경고

### Metrics

- median unit price
- Q1/Q3/IQR
- subject/median ratio
- robust z-score using MAD when possible
- percentile

### Trigger

기본 internal signal:

```text
ratio >= 3.0 AND robust_z >= 3.5
OR ratio >= 5.0 with n >= 5
```

이는 법적 기준이 아니다.

### Blocking conditions

- bundle unknown/incomparable
- installation/training/maintenance unknown and potentially material
- military/medical/security certification unknown
- model/variant unresolved
- unit conversion uncertain
- VAT/shipping basis unknown
- source record possibly amended/cancelled
- fewer than minimum independent comparables without editor exception

### Public explanation

subject price, median, n, date/spec filters, exclusions, unknowns를 구조화해 표시한다. 단일 retailer 가격만으로 public claim 금지.

### False positives

- 소량 긴급 납품
- 장기 warranty/SLA
- custom packaging
- site installation
- specialized certification
- obsolete model scarcity
- typographical quantity
- total price mistaken for unit price

## 5. 규칙 2 — `CONTRACT_SPLITTING_PATTERN_V1`

### 목적

유사한 목적의 계약이 짧은 기간 여러 건으로 나뉜 패턴을 찾는다. **법적 계약 분할 판정이 아니다.**

### Candidate grouping

- same agency budget unit or department when available
- same supplier or related verified supplier
- same normalized category/project token
- signed within 30 days; secondary windows 7/90 days
- each contract below versioned analytical threshold band

법적 수의계약 한도는 법령·계약 유형·시점에 따라 달라질 수 있으므로 `JurisdictionPolicyVersion`에서 effective-date 기준으로 읽는다. 값이 없으면 법 위반 문구를 생성하지 않는다.

### Metrics

- group count and cumulative amount
- interval distribution
- description similarity
- independent purpose evidence
- procurement plan/notices linkage

### Trigger example

3건 이상, 30일, cumulative amount가 analytical band를 넘고 description similarity 높음.

### Blocking/counterevidence

- distinct delivery locations or budgets
- recurring consumables schedule
- emergency events
- framework/call-off contract
- separate project codes and deliverables
- source duplication

## 6. 규칙 3 — `REPEATED_SINGLE_SOURCE_V1`

### 목적

동일 기관-업체-품목군의 반복 수의/단독 계약을 탐지.

Metrics:

- 90/365일 count and amount
- share of agency category spend
- alternative supplier history
- stated legal basis categories
- recurrence intervals

Trigger default:

- 90일 3건 또는 365일 6건
- category spend share >= 50%
- data coverage >= 80%

Blocking:

- exclusive rights/compatibility official basis
- disaster/emergency
- framework agreement
- sole certified supplier
- incomplete category coverage

Public wording은 반복 사실과 공개된 계약 사유만 말하며 “특혜”라고 단정하지 않는다.

## 7. 규칙 4 — `SUPPLIER_CONCENTRATION_V1`

### 목적

기관·품목·기간 내 계약금액이 소수 업체에 집중된 패턴.

Metrics:

- top-1/top-3 share
- HHI
- contract count share
- winner persistence
- bidder coverage

Peer baseline:

기관 규모·업무·품목군이 유사한 peer group. Data coverage가 다르면 public comparison 금지.

Trigger:

- top-1 share >= 70% and amount/count minimum
- 또는 HHI가 peer P95 이상

False positives:

- 지역 독점 공급
- proprietary maintenance
- framework supplier
- narrow specialized market
- incomplete data

## 8. 규칙 5 — `LOW_COMPETITION_V1`

### 목적

경쟁입찰 공고에 참여/유효 입찰자 수가 반복적으로 낮은 경우.

Inputs:

- notice/award link
- bidder count definition
- re-bid/failed bid history
- restrictions

Metrics:

- single-bid rate by agency/category
- bidder count vs peer
- repeated same winner
- notice duration

Blocking:

- source가 참여자 수를 완전 제공하지 않음
- emergency/failed rebid context
- highly specialized requirement

## 9. 규칙 6 — `CONTRACT_AMENDMENT_ESCALATION_V1`

### 목적

계약 후 금액·기간이 크게 증가하거나 변경이 반복된 패턴.

Metrics:

- total delta/original amount
- number of amendments
- duration extension
- reason categories
- tender amount vs final amount

Trigger default:

- cumulative amount increase >= 20% and >= 2 amendments
- 또는 increase >= 50%
- 단, engineering change나 price adjustment mechanisms context 필요

Blocking:

- inflation/indexation clause
- scope addition with separate approval
- disaster/emergency
- source missing negative/credit amendments

## 10. 규칙 7 — `YEAR_END_SPEND_SPIKE_V1`

### 목적

회계연도 말 특정 품목·업체 지출이 기관의 계절 패턴보다 급증.

Metrics:

- Q4/December share
- historical 3-year baseline
- peer institution baseline
- contract lead time
- cancellation/next-year delivery

Trigger:

- year-end share > historical median + 3 MAD and amount minimum

주의:

계절 사업, 회계 집행 일정, 정기 renewal, 공사 기성금은 정상일 수 있다. “예산 털기” 표현 금지.

## 11. 규칙 8 — `NEW_SUPPLIER_DEPENDENCY_V1`

### 목적

신규/최근 상태 변경 업체가 특정 기관 계약에 과도하게 의존하거나 단기간 큰 계약을 받은 패턴.

Inputs:

- verified business start/status if lawfully available
- public contract history coverage
- agency share of public revenue proxy

금지:

공공계약만으로 업체 전체 매출 의존도를 단정하지 않는다. 표현은 “관측된 공공계약 중 해당 기관 비중”으로 제한.

Blocking:

- incomplete historical data
- corporate reorganization/name change
- spin-off/merger
- framework transfer

## 12. 규칙 9 — `SHARED_IDENTIFIER_NETWORK_V1`

### 목적

여러 supplier가 공식 공개 식별자(주소, 전화, 임원 등)를 공유하는 후보를 생성.

제약:

- lead only
- 개인 family relation inference 금지
- exact official shared identifiers만
- co-working/shared office, accountant phone 등 false positive 검토
- public graph는 verified relation만

Trigger output은 `ENTITY_RELATION_CANDIDATE`, corruption signal이 아니다.

## 13. 규칙 10 — `SPECIFICATION_RESTRICTIVENESS_V1`

### 목적

입찰 규격이 불필요하게 특정 제품/업체만 충족할 가능성이 있는 lead.

혼합 방법:

1. deterministic features:
   - named trademark/model count
   - exact dimensions/tolerances
   - unusual bundled requirements
   - short submission window
   - restrictive certification combination
2. LLM candidate extraction:
   - 규격 문구와 대체 가능성 후보
3. human/market verification

LLM output만으로 signal publish 금지. 실제 대체 제품군과 법적 허용 사유 검토 필요.

## 14. Rule suppression taxonomy

```text
INSUFFICIENT_DATA
UNIT_INCOMPATIBLE
VAT_UNKNOWN
BUNDLE_UNKNOWN
SPEC_UNKNOWN
IDENTITY_AMBIGUOUS
SOURCE_STALE
SOURCE_DUPLICATE
CONTRACT_CANCELLED
AMENDMENT_UNRESOLVED
LEGAL_POLICY_UNKNOWN
KNOWN_FRAMEWORK_AGREEMENT
EMERGENCY_CONTEXT
EXCLUSIVE_RIGHTS_CONTEXT
OUT_OF_SCOPE_SECURITY
```

Suppression reason은 eval과 methodology transparency에 집계한다.

## 15. 우선순위 모델

Internal priority는 공개 score가 아니다.

```text
priority =
  public_money_impact_band
+ evidence_coverage
+ rule_strength
+ recurrence
+ citizen_safety_impact
+ source_independence
- known_false_positive_risk
- identity_uncertainty
- stale_data_penalty
```

정치·고객·후원·SNS popularity는 입력 금지. 각 feature와 weight는 versioned.

## 16. Multi-signal case aggregation

같은 subject/time/project에서 여러 rule이 발생하면 무조건 confidence를 곱하지 않는다. Correlated features가 중복일 수 있다. Aggregator는:

- signal provenance
- shared inputs
- independent sources
- duplicate metrics

을 기록하고 case priority만 보조한다.

## 17. 평가와 calibration

### Gold labels

- `INVESTIGATE`
- `DISMISS_DATA_ERROR`
- `EXPLAINED`
- `INSUFFICIENT`
- `PUBLICATION_ELIGIBLE_AFTER_REVIEW`

“CORRUPT” label을 쓰지 않는다.

### Metrics

- signal precision/recall by rule
- triage acceptance rate
- blocking correctness
- publication policy violation
- false identity merge
- explanation completeness
- reproducibility
- cohort stability

### Calibration cycle

- shadow rule 실행
- gold/false-positive eval
- investigator blind review
- threshold proposal
- methodology diff
- approval and new RuleVersion
- backtest impact report
- no silent retroactive overwrite

## 18. 공개 통계의 공정성

기관별 raw signal count는 데이터량과 source coverage에 강하게 영향을 받는다. Public comparison에는:

- contracts observed
- amount coverage
- time range
- source families
- missingness
- denominator
- uncertainty

을 같이 표시한다. Coverage가 비교 불가능하면 ranking을 만들지 않는다.

## 19. 모델 발전과 방법론

더 긴 context/model이 나와도 다음은 바뀌지 않는다.

- model은 evidence를 만들지 않는다.
- publication approval은 사람 전용.
- deterministic metric은 code에서 계산.
- prompt/model 변경은 versioned eval 필요.
- 더 똑똑한 모델이라는 이유로 safety gate를 제거하지 않는다.
