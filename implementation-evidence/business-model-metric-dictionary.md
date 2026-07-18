# Gurinnae Business Model Metric Dictionary

Status: `REVIEW_REQUIRED`

Contract: `2026-07-15.business-model.r3`

Authority SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

이 문서는 `specs/product/business-model-contract.yaml`의 사람이 읽는 운영 사전이다. 수식, window, exclusion, source, owner, breach action 또는 unknown 처리에 충돌이 있으면 YAML의 동일 metric ID/version이 우선한다. 현재 cross-file blocker가 열려 있고 supplemental catalog의 41개 행은 모두 `implementation_status: MISSING`이므로 이 문서는 release-ready 또는 LGTM 증거가 아니다.

## 고정된 사업 축

- 첫 고객: 반복 조달 조사자 3–20명을 둔 한국 탐사보도 조직 또는 공익 연구 조직
- 경제적 구매자: 조사 편집자 또는 연구 책임자
- 첫 상품: 물리적으로 격리된 단일 조직 `EVIDENCE_WORKSPACE_ORGANIZATION_V1`
- 유료 job: 권한 있는 조달 자료를 재현 가능한 증거 packet으로 만들고 사람의 독립 검토를 거쳐 책임 있는 결정 또는 전달 receipt까지 닫는 반복 workflow
- 무료 경계: 공개 사실·근거 locator·revision·정정/철회·응답/appeal·privacy/rights·방법론·source coverage·funding/governance·basic subscription은 영구 무료
- 유료 경계: 격리된 private workspace의 authorized ingestion, multimodal batch analysis, saved cohort/schedule, collaboration/review, organization-only API/export/channel, SLA/support와 audited private receipt만 계약·quota 대상이다. 계약 만료·청구 실패·quota 소진은 이 private 처리만 막을 수 있고 무료 사실·검증·권리 동선은 줄이거나 지연할 수 없다.
- 금지된 교환: 돈, margin, CAC 또는 고객 중요도가 detection, evidence, wording, response, correction, privacy, accessibility, publication 또는 approval gate를 바꿀 수 없다.

## 운영 퍼널

| 단계 | 정확한 진입 증거 | 진입으로 인정하지 않는 것 |
|---|---|---|
| `QUALIFIED` | recurring job, authorized data, buyer, operational owner, independent reviewer, rights owner, budget와 trust acceptance를 하나의 policy/evidence-set digest로 묶은 최소 immutable qualification receipt | lead, page view, meeting, acquisition receipt, proposal |
| `CONFIGURED` | qualification episode와 동일 cutoff에서 ACTIVE+PROVISIONED contract, PAID_WORKSPACE_PROCESSING 승인/활성 receipt, OIDC/roster/isolation readiness를 deterministic projection | sandbox, fixture, connection-green, 별도 stage row/event |
| `DATA_READY` | 동일 episode에서 core readiness READY, non-empty immutable DatasetSnapshot, rights, coverage/freshness/limitation을 earliest qualifying cutoff로 projection | source run started, empty/fixture snapshot, connector green, 별도 stage row/event |
| `FIRST_PAID_VALUE` | DATA_READY 뒤 active contract interval의 최초 strict paid outcome head를 projection | triage, review, proposal, AI output, invoice, 별도 stage row/event |
| `ACTIVATED` | projected FIRST_PAID_VALUE 존재. 7일 이하는 on-time, 7일 초과는 late. P90 목표는 14일 | backdate 또는 미성숙 cohort |
| `RETAINED` | activation 뒤 29일 이상 57일 미만에 추가 strict paid MVW 2개 이상이며 평가시 trailing 30일에도 1개 이상인 as-of projection | activation workflow 재사용, retry 중복 |
| `AT_RISK` | trailing 30일 무가치, 성숙 retention 실패, 또는 72시간 초과 readiness/SLA BLOCKED·UNKNOWN인 as-of projection | churn 추정, 별도 상태 mutation |
| `CHURNED` | current contract leaf가 ENDED/CANCELLED이고 active/suspended replacement가 없다는 as-of projection | 단순 inactivity, 별도 churn receipt |

퍼널에서 새로 필요한 물리 authority는 **`ops.commercial_qualification_receipts` 하나뿐**이다. 이는 사람의 qualification episode 결정을 append-only로 보존한다. `CONFIGURED` 이후 모든 단계는 기존 immutable contract, activation, readiness, snapshot, outcome, invoice와 SLI fact를 같은 `as_of`, formula/policy digest로 읽는 deterministic projection이다. `commercial_lifecycle_facts`, stage fact/event ledger 또는 이름만 바꾼 generic lifecycle relation은 금지한다.

## strict paid MVW

`BM-VALUE-PAID-MVW`는 `ops.outcome_facts`의 current correction-chain head 하나를 단위로 센다. 다음 둘만 eligible하다.

1. `AUDITED_DELIVERY` + 적용된 `DELIVERED|READ` `OUTBOUND_DELIVERY` receipt
2. `COMPLETED_DECISION_CYCLE` + finalized `ORGANIZATION_DECISION` receipt

둘 모두 organization scope, production, current ACTIVE+PROVISIONED contract, DATA_READY 이후 interval, exact four-milestone workflow proof, `PaidEvidencePacketV1`, human decision, independent-review disposition과 durable receipt를 요구한다. `TRIAGED_SIGNAL`, `REVIEWED_INVESTIGATION`, `ACCEPTED_PROPOSAL`, `PUBLICATION`, `CORRECTION`, public outcome, draft/fixture/failed work와 AI/model/tool/citation output alone은 0개가 아니라 **ineligible**이다. 증거가 불완전하거나 chain이 모호하면 **UNKNOWN candidate**로 별도 집계한다.

## 공통 계산 규칙

- 모든 interval은 `[start,end)`이며 contract accounting timezone의 calendar boundary를 UTC로 정확히 변환한다.
- PostgreSQL `numeric`과 `ops.round_half_even_numeric_v1`만 사용한다. binary float와 PostgreSQL 기본 `round()`를 사용하지 않는다.
- denominator 0은 `NOT_APPLICABLE`이다. 관측 누락은 `UNKNOWN`이며 0 또는 healthy가 아니다.
- eligible 조직이 5개 미만이면 count/unknown만, 5개 이상이면 rate와 Wilson 95% interval을 함께 표시한다. 자동 scale/stop 결정은 immediate trust stop 외에는 eligible 10개 이상을 요구한다.
- 모든 결과는 `metricId`, `version`, `formulaDigest`, `inputSetDigest`, `window`, `asOf`, `status`, `reasonCode`, `freshness`, `unknownReasonCounts`, `breachAction`, `issueCode`를 포함한다.
- `status`는 정확히 `KNOWN|UNKNOWN|NOT_APPLICABLE`이다. `KNOWN`은 `reasonCode=NONE`; `UNKNOWN`은 null value와 가장 우선인 non-`NONE` reasonCode 및 typed owner action; `NOT_APPLICABLE`은 null value와 `DENOMINATOR_ZERO|COHORT_NOT_MATURE|SAMPLE_TOO_SMALL|CAPABILITY_NOT_OFFERED` 중 하나를 가진다. 누락·stale·ambiguous evidence는 N/A가 아니라 UNKNOWN이다.
- correction은 새 as-of 결과와 input digest를 만들며 과거 receipt를 수정하지 않는다.
- 모든 25개 metric은 YAML 안에 `breach_action`과 `healthy_issue_code: NONE`을 직접 가진다. KNOWN PASS/정상 NOT_EVALUATED와 정당한 NOT_APPLICABLE은 `issueCode=NONE`, `breachAction=NONE`이다. UNKNOWN 또는 BREACH는 절대 NONE이 아니며 typed owner action을 가진다.

## Metric dictionary

| Metric ID (v1) | 수식과 window | authoritative source | exclusion / unknown | owner / threshold / breach action |
|---|---|---|---|---|
| `BM-ACQ-QUALIFIED-ORG-COUNT` | cohort month valid qualification receipt의 organization distinct count | qualification, acquisition receipts | acquisition-only/lead-only 제외; 기준 누락=UNKNOWN | Sales/CS/Finance; contextual; breach: qualification evidence 완결 전 funnel 사용 금지 |
| `BM-ACQ-CHANNEL-MIX` | qualified org를 current acquisition `source_kind`별 distinct count | qualification/acquisition receipt heads | person touchpoint 금지; unattributed=`UNKNOWN_SOURCE` | PdM + Sales/CS/Finance; breach: weak/unknown channel scale 중지 |
| `BM-FUNNEL-CONFIGURATION-RATE` | 14일 성숙 qualified cohort 중 14일 내 derived CONFIGURED / matured qualified | qualification, contract, activation, readiness | reversed qualification/non-production 제외; receipt 누락은 denominator 내 UNKNOWN | Sales/CS/Finance + SRE; n≥10에서 0.80; breach: `COMPLETE_CONFIGURATION` |
| `BM-FUNNEL-DATA-READY-RATE` | 14일 성숙 configured cohort 중 14일 내 derived DATA_READY / matured configured | qualification, contract, readiness, snapshot | empty/fixture/expired rights 제외; missing coverage=UNKNOWN | Data/Engineering + PdM; n≥10에서 0.80; breach: `REPAIR_DATA_READINESS` |
| `BM-VALUE-PAID-MVW` | accounting month strict eligible `root_fact_id` distinct count | outcome, qualification, contract/readiness, terminal receipts | triage/review/proposal/publication/correction/public/AI-only 제외; unresolved proof=UNKNOWN | PdM; activation 1, retention 추가 2; breach: packet 검증/value recovery |
| `BM-VALUE-PAID-MVW-PER-ACTIVE-ORG` | **동일 qualification cohort/episode + revenue-qualified org set + SKU/timezone/window/cutoff**의 paid MVW / 해당 org count | outcome, qualification, contract, invoice | denominator 0=N/A; global·cross-cohort numerator와 cohort-ratio 평균 금지; incomplete=UNKNOWN | PdM; contextual; breach: UNKNOWN이면 expansion/renewal/scale 사용 금지 |
| `BM-ACTIVATION-7D-RATE` | 7일 성숙 DATA_READY cohort 중 first value ≤168h / matured DATA_READY | qualification, contract/readiness/snapshot, outcome | pre-ready/inactive outcome 제외; 성숙 no-value=failure | PdM; n≥10에서 ≥0.80; breach: cohort/value recovery |
| `BM-ACTIVATION-TTFPV-P90` | rolling 90-day cohort의 P90(first value - data ready), hours | qualification, contract/readiness/snapshot, outcome | negative/corrected/inactive 제외; n<5 percentile 미주장 | PdM + Data; ≤336h; breach: slow blocker repair |
| `BM-RETENTION-D29-56-RATE` | day 57 성숙 activated cohort 중 `[+29d,+57d)` 추가 paid MVW ≥2 / matured activated | qualification, contract, outcome | activation unit/retry 제외; incomplete chain=UNKNOWN | PdM + Sales/CS; n≥10에서 ≥0.70; breach: value recovery |
| `BM-RETENTION-AT-RISK-ORG-COUNT` | current non-churned org 중 trailing 30d no value, matured retention fail, readiness/SLA unknown/block >72h | qualification, contract, outcome, readiness, SLI | churned/아직 data-ready 전 계획 pilot 제외; missing itself is reason | Sales/CS + PdM; 1 business day owner; breach: recovery owner 지정 |
| `BM-RETENTION-CHURN-RATE` | month 중 derived churn org / window-start active-or-suspended org | qualification, contract state intervals | inactivity/at-risk/replacement 제외; successor ambiguity=UNKNOWN | Sales/CS/Finance; breach: every churn review/new episode |
| `BM-FUNNEL-PILOT-TO-PAID-RATE` | 60일 성숙 qualified cohort 중 positive recognized revenue와 strict paid MVW 모두 존재 / matured qualified | qualification, contract, revenue, outcome | signed/invoice-only/fixture/reversed revenue 제외 | Sales/CS/Finance + PdM; n≥10에서 ≥0.30; breach: cohort/billing repair |
| `BM-REVENUE-QUALIFIED-ORG-COUNT` | current ACTIVE+PROVISIONED org 중 trailing 30d positive reconciled invoice와 strict paid MVW 모두 존재 | contract, invoice membership, outcome | signed/unprovisioned/inactive/no-value 제외; incomplete=UNKNOWN | Finance; contextual; breach: billing/packet reason별 repair |
| `BM-EXPANSION-ELIGIBILITY-RATE` | two complete months와 trailing 60d의 demand/value/reconciliation/margin/support/readiness/SLA/trust를 모두 통과한 org / matured revenue-qualified org | qualification, usage/invoice/outcome/revenue/cost/readiness/SLI | 2개월 미만 제외; 하나라도 unresolved이면 aggregate UNKNOWN/null | Sales/CS/Finance + PdM + SRE; no growth target; breach: expansion offer 금지 후 blocker closure |
| `BM-RENEWAL-ELIGIBILITY-RATE` | period_end가 `(as_of,as_of+60d]`인 contract 중 trailing 90d/two-month gate를 모두 통과 / decision-window contracts | qualification, contract/invoice/outcome/revenue/cost/readiness/SLI | inactive, 2개월 미만, superseded 제외; unresolved이면 UNKNOWN/null | Finance + PdM/SRE/Trust; no revenue target; breach: renewal recommendation 금지 |
| `BM-REVENUE-RECOGNIZED-KRW` | month overlap effective recognized amount half-even sum | revenue facts, accounting corrections | commitment/invoice/tax/reversed 제외; broken chain=UNKNOWN | Finance; actual fact; breach: UNKNOWN이면 revenue/margin/renewal claim 금지 |
| `BM-BILLING-RECONCILIATION-COVERAGE` | exactly-one current membership COMPLETE usage roots / due COMPLETE usage roots | usage receipts/facts, `ops.invoice_usage_memberships`, invoices/lines | PARTIAL/UNKNOWN 별도; silent denominator removal 금지 | Finance + Data; exactly 1.0; breach: invoice/revenue/readiness 차단 |
| `BM-MARGIN-VARIABLE-GROSS-RATE` | `(recognized revenue - eligible variable cost) / revenue`, month/P75 cohort | revenue, cost, FX, tariff | CAC/tax 제외; zero revenue=N/A; incomplete cost/FX=UNKNOWN | Finance + SRE; pilot ≥0.60, GA ≥0.70; breach: cost gap 또는 price/quota/efficiency 조정 |
| `BM-MARGIN-CONTRIBUTION-KRW` | recognized revenue - eligible variable cost | revenue, cost, FX | CAC/tax 제외; unknown/unallocated=UNKNOWN | Finance; GA 전 positive; breach: nonpositive면 product pause review |
| `BM-COST-PER-PAID-MVW-KRW` | outcome-allocated variable cost / paid MVW | cost allocation, outcome | public/CAC 제외; zero MVW=N/A; gap=UNKNOWN | PdM + SRE; contextual; breach: quality/trust 손상 없이 allocation/efficiency repair |
| `BM-CAC-KRW` | complete captured acquisition set의 attributed SALES_CUSTOMER_ACQUISITION 합 | cost, acquisition receipt, FX | reversed/person-level/editorial 제외; **unattributed cost가 있으면 전체 status UNKNOWN** | Finance; payback input; breach: paid channel 중지/attribution closure |
| `BM-CAC-PAYBACK-MONTHS` | CAC / trailing 3 complete months average positive contribution | CAC, revenue, cost | 3개월 미만=N/A; nonpositive이면 status UNKNOWN + `NONPOSITIVE_CONTRIBUTION` + null | Finance; ≤12m; breach: GA/paid acquisition pause |
| `BM-SLA-AVAILABILITY-RATE` | `(eligible minutes - union unavailable minutes) / eligible minutes`, accounting month | SLI, contract, incidents | allowed maintenance만 제외; telemetry/target missing=UNKNOWN | SRE; signed target; breach: SLA/telemetry 복구 및 service credit |
| `BM-SUPPORT-HOURS-PER-ACTIVATED-ORG` | support+material-correction hours / activated org | cost, qualification, contract, outcome | sales/public/fixture 제외; incomplete capture=UNKNOWN | Sales/CS + SRE; ≤4h; breach: support capacity 복구 |
| `BM-TRUST-HARD-STOP-COUNT` | validated hard-stop incidents distinct count, trailing 12m + unresolved lifetime | incident, audit, conflict | invalidated duplicate 제외/history 보존; suspicion blocks scale | Trust/Privacy/Legal + Editorial; target 0; breach: 즉시 containment |

## Pricing, invoice, revenue

순 월 요금은 prorated workspace base, active-contributor block, processing-credit overage, storage GB-month overage, API Record Unit overage, 선택 SLA, effective discount와 append-only accounting adjustment의 합이다. case/signal/publication/subject/sensitivity는 절대 meter가 아니다. Signed webhook/digest quota는 v1 included limit이며 undeclared overage를 만들지 않는다.

`PARTIAL|UNKNOWN` usage는 0이 아니며 자동 청구하지 않는다. `ops.read_invoice_membership_v1`은 관측 상태나 overage로 필터링하기 전에 due meter/window grid를 반환한다. 각 current `COMPLETE` usage root는 `ops.invoice_usage_memberships` current leaf에 정확히 한 번 나타난다. `ZERO_USAGE|INCLUDED_ALLOWANCE`는 charge line 없이도 물리 membership row를 가지며 `BILLED_OVERAGE`만 동일 invoice의 line에 결속된다. line ordinal, membership/line-set digest, subtotal/discount/tax/correction/total 보존식 중 하나라도 어긋나면 reconciliation은 UNKNOWN/BLOCKED이고 그 invoice는 revenue, margin 또는 readiness의 정상 증거가 아니다.

Revenue는 current immutable `ops.revenue_facts`만이다. 계약 commitment와 invoice total은 각각 commitment와 billing fact이며 자동 revenue가 아니다. Revenue correction은 append-only이다.

## Readiness와 channel rollout

`PILOT_ENTRY_READINESS`는 funnel `ACTIVATED`와 다른 pre-activation admission gate이며 mandatory가 정확히 14개다: paid processing activation, deployment isolation, OIDC/roster, data/key/queue isolation, source rights, telemetry/alert/runbook, backup/restore, incident ownership, current contract/tariff, billing/cost path, P75 pilot margin과 support capacity. 실제 billing 이후 3개가 추가되어 17개, GA에서 CAC가 추가되어 18개다.

Public Web, verified email, API/export, webhook, daily/weekly digest와 SMS/Telegram/WhatsApp/LINE/Kakao/voice는 정확히 12개 conditional row이며 **signed offer에 포함된 경우에만** blocking requirement다. 판매하지 않은 channel은 NOT_APPLICABLE/UNCONFIGURED이며 core pilot을 막지 않는다. 판매한 순간 exact provider/legal/consent/cost production activation receipt가 필요하다. R3 `0029-invoice-revenue-sku.yaml`의 물리 계약은 이 14/17/18 mandatory, 12 conditional, stage별 26/29/30 visible item count로 교정되었다. 다만 migration/evaluator/generated inventory와 every-offered-subset runtime proof는 아직 OPEN이다.

## OPEN cross-file blockers

이 세 파일만으로 닫을 수 없는 다음 항목은 의도적으로 OPEN이다.

- Qualification authority: 최소 `ops.commercial_qualification_receipts`와 typed importer/catalog/runtime가 아직 없다. 다른 stage ledger/event는 만들지 않는다.
- Readiness catalog: R3 물리 계약은 CLOSED지만 migration/evaluator/generated inventory와 every-offered-subset runtime proof가 OPEN이다.
- Paid packet/terminal registry: `PaidEvidencePacketV1`과 물리 `ORGANIZATION_DECISION` resolver가 없다.
- Invoice membership: R3 물리 계약은 `ops.invoice_usage_memberships`와 `ops.read_invoice_membership_v1`로 CLOSED지만 global registry, migration, repository/function runtime과 canary 실행이 OPEN이다.
- SLA: R3 물리 계약은 signed policy/target/capability/exclusion/credit/measurement tuple과 `ops.read_sla_metric_inputs_v1`로 CLOSED지만 migration/runtime/incident/service-credit 실행이 OPEN이다.
- Revenue overlap: R3 물리 계약은 line+policy lock, exact half-open predicate와 correction semantics로 CLOSED지만 SQL/function/catalog/concurrency 실행이 OPEN이다.
- Unattributed CAC: R3 물리 계약은 ATTRIBUTED/UNATTRIBUTED pool과 `ops.read_cac_metric_inputs_v1`로 CLOSED지만 migration/repository/function/property-test 실행이 OPEN이다.
- API: 기존 다섯 operation DTO/OpenAPI/generated client가 25개 business metric과 evidence types를 아직 노출하지 않는다.
- Runtime/mapping: 41개 supplemental catalog 행과 `skip_policy: FORBIDDEN`은 존재하지만 모두 `implementation_status: MISSING`이고 선언한 Rust test/package, SvelteKit states/browser 및 production smoke가 없다.

따라서 feature tag는 `@additive-review`이고 contract status는 `REVIEW_REQUIRED`이다. 위 blocker가 닫히고 41개 scenario가 `skip_policy: FORBIDDEN`으로 실제 실행되기 전에는 `@final`, LGTM 또는 release-ready를 주장하지 않는다.

## 화면과 operation

- `INT-001 / getInternalDashboard`: `budgets.manage`를 함께 가진 actor에게 identity/amount 없는 aggregate pulse만 제공
- `OPS-004 / getBudgetOverview`: funnel, paid MVW, retention, revenue, reconciliation, margin, CAC, SLA/support unknown을 `BusinessHealthV1`로 제공
- `OPS-004 / exportCostReport`: formula/policy/input digests와 correction head를 포함한 audited evidence export
- `OPS-001 / getOperationsOverview`: commercial readiness, SLA, telemetry gap, incident와 owner
- `AUD-001 / searchAuditEvents`: qualification, metric policy, reconciliation, correction, pause/resume receipt

새 surface, checkout, tenant switcher, payment 또는 CRM route를 만들지 않는다. Business panel은 read-only이고 dashboard click으로 accounting/editorial/commercial fact를 변경하지 않는다.

## 주요 risk owner

- Market/job fit: PdM이 activation·retention·pilot-to-paid·paid MVW를 같은 cohort 정의로 본다.
- Data rights/quality: Data/Engineering과 Trust가 rights·coverage·freshness·parser·snapshot·locator 누락 시 해당 DATA_READY와 value를 막는다.
- AI provenance: AI/Data와 독립 reviewer가 model/tool/source/citation/counter-evidence 결속 누락 시 abstain/quarantine한다.
- Billing integrity: Finance와 Data가 usage→membership→invoice→revenue chain의 gap, duplicate, rounding, over-recognition을 막고 append-only correction한다.
- Variable cost/CAC/support: Finance·SRE·PdM이 price, quota, routing, workflow와 onboarding을 조정하되 quality/trust gate는 건드리지 않는다.
- SLA/recovery: SRE가 telemetry gap을 UNKNOWN incident로 처리하고 restore/reconciliation/service-credit receipt를 닫는다.
- Independence/privacy: Trust/Privacy/Legal과 Editorial duty가 customer influence, cross-deployment access, reuse, rights bypass 또는 conflict nondisclosure를 즉시 hard stop한다.
- Concentration: Executive/Finance/SRE/Editorial이 source/provider/channel/customer/funder concentration과 tested fallback을 함께 검토한다.

## 계속·중지 규칙

Scale candidate는 n≥10의 activation ≥80%, P90 ≤14일, retention ≥70%, pilot-to-paid ≥30%, 두 달 연속 stage margin 목표, billing reconciliation 100%, support ≤4h, trust hard stop 0과 모든 hard gate READY를 동시에 요구한다.

다음은 신규 GA sale/paid acquisition을 pause한다: 두 성숙 cohort 연속 activation 또는 retention <50%, pilot-to-paid <20%; 두 달 연속 actual margin <40%; 한 달 contribution ≤0; 두 달 연속 support >8h; 두 eligible cohort 연속 CAC payback >18개월. 기존 고객은 안전하게 이행하고, dated correction evidence와 Finance/PdM/SRE 독립 승인 뒤에만 resume한다.

Unauthorized customer-data reuse, commercial editorial influence, billing unknown usage 또는 production rights/activation 부재는 sample size와 무관한 즉시 hard stop이다. 어떤 growth 지표도 이를 상쇄하지 못한다.
