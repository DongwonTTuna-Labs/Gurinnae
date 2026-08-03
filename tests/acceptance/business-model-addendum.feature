@hard-gate @final @supplemental @additive-review @business-model @product-economics
# contract-status: FINAL
# execution-mapping-required: catalog rows present; implementation paths and executing commands are currently MISSING
Feature: Evidence Workspace 비즈니스 모델과 운영 퍼널
  단일 조직 Evidence Workspace가 실제 검증 워크플로의 가치를 전달하고
  수익·비용·신뢰를 서로 바꾸어 쓰지 않으며 운영 가능해야 한다.

  # scenario-id: AC-BUSINESS_MODEL-001
  Scenario: 첫 고객과 구매자와 사용자가 고정된다
    Given 현재 business model contract를 읽는다
    Then 첫 고객은 3명에서 20명의 반복 조달 조사자를 둔 한국 탐사보도 또는 공익 연구 조직이어야 한다
    And 경제적 구매자는 조사 편집자 또는 연구 책임자여야 한다
    And 첫 SKU는 단일 조직 Evidence Workspace여야 한다
    And 다중 tenant SaaS와 self-service checkout과 기관 감사 및 일반 compliance 제품은 범위 밖이어야 한다

  # scenario-id: AC-BUSINESS_MODEL-002
  Scenario: 비참여자는 성장 또는 과금 대상으로 전환되지 않는다
    Given 공개 독자와 응답 주체와 공급자와 기관과 제보자가 있다
    Then 이들은 lead와 billable unit과 광고 audience와 교차 session profile이 아니어야 한다
    And 이들의 응답 정정 appeal privacy 접근은 고객 계약과 무관해야 한다

  # scenario-id: AC-BUSINESS_MODEL-003
  Scenario: qualification은 완전한 서명 receipt로만 성립한다
    Given 한 조직에 반복 조사 job과 authorized data와 buyer와 operational owner와 independent reviewer와 budget과 trust acceptance가 모두 있다
    When 동일 policy 및 evidence-set digest의 minimal qualification receipt가 기록된다
    Then 조직은 QUALIFIED여야 한다
    And acquisition receipt나 meeting이나 proposal만으로 qualification을 추론하지 않아야 한다
    And 새 cross-file business relation은 ops.commercial_qualification_receipts 하나뿐이어야 한다
    And commercial_lifecycle_facts stage fact 또는 general stage event를 만들지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-004
  Scenario: qualification 관측 누락은 unqualified로 둔갑하지 않는다
    Given qualification 기준 중 source-rights owner receipt가 없다
    When qualification metric을 계산한다
    Then 조직은 numerator에 들어가지 않아야 한다
    And unknown_count와 누락 기준이 보여야 한다
    And unqualified 또는 zero로 추정하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-005
  Scenario: configuration은 계약과 provisioning과 activation을 모두 요구한다
    Given ACTIVE 및 PROVISIONED contract period가 있다
    And 같은 configuration의 PAID_WORKSPACE_PROCESSING 결정과 production evidence가 APPROVED 및 ACTIVE이다
    And OIDC roster isolation prerequisite가 만족된다
    When 동일 as_of에서 existing immutable contract activation readiness fact를 projection한다
    Then 조직은 CONFIGURED여야 한다
    But fixture-only 또는 만료되거나 다른 configuration의 receipt는 통과하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-006
  Scenario: data ready는 실제 non-empty snapshot과 limitation을 요구한다
    Given core pilot readiness가 READY이다
    And authorized non-empty DatasetSnapshot이 immutable하고 재현 가능하다
    And source coverage freshness limitation과 rights receipt가 현재이다
    When 동일 as_of에서 readiness evaluation 및 snapshot-set을 projection한다
    Then data_ready_at이 activation clock의 시작이어야 한다
    But connector green이나 source-run started나 fixture snapshot만으로 DATA_READY가 되지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-007
  Scenario: core pilot은 판매하지 않은 channel 때문에 막히지 않는다
    Given Public Web email API webhook digest SMS Telegram WhatsApp LINE Kakao와 voice를 pilot offer에 넣지 않았다
    When BM-PILOT-CORE-V1 readiness를 평가한다
    Then 해당 항목은 NOT_APPLICABLE 또는 UNCONFIGURED로 보여야 한다
    And core pilot을 BLOCKED로 만들지 않아야 한다
    But offer에 명시한 channel은 exact production activation evidence 없이 READY가 되지 않아야 한다
    And mandatory item은 PILOT_ENTRY_READINESS 14개 post-first-billing 17개 GA 18개여야 한다
    And Public Web email API webhook daily 및 weekly digest SMS Telegram WhatsApp LINE Kakao voice는 정확히 12개 conditional item이어야 한다
    And stage의 visible item count는 offered subset과 무관하게 각각 26개 29개 30개여야 한다

  # scenario-id: AC-BUSINESS_MODEL-008
  Scenario: paid MVW는 책임 있는 terminal outcome만 센다
    Given organization scope의 production outcome fact가 있다
    And active provisioned contract와 DATA_READY 뒤의 유효 interval이다
    When fact type과 terminal receipt가 AUDITED_DELIVERY 및 OUTBOUND_DELIVERY이거나 COMPLETED_DECISION_CYCLE 및 ORGANIZATION_DECISION이다
    And packet proof human decision independent review 및 durable receipt가 exact digest로 결속된다
    Then BM-VALUE-PAID-MVW는 root outcome chain을 한 번 세어야 한다

  # scenario-id: AC-BUSINESS_MODEL-009
  Scenario Outline: 중간 산출물을 paid MVW로 과대계상하지 않는다
    Given current organization outcome의 fact type이 <fact_type>이다
    When BM-VALUE-PAID-MVW를 계산한다
    Then 이 outcome은 paid MVW에서 제외되어야 한다

    Examples:
      | fact_type             |
      | TRIAGED_SIGNAL        |
      | REVIEWED_INVESTIGATION |
      | ACCEPTED_PROPOSAL     |
      | PUBLICATION           |
      | CORRECTION            |

  # scenario-id: AC-BUSINESS_MODEL-010
  Scenario: AI output은 스스로 가치 receipt가 아니다
    Given agent proposal과 model output과 tool call과 citation UUID가 있다
    But human decision과 independent review와 responsible terminal receipt가 없다
    When paid MVW와 first paid value를 계산한다
    Then 두 값 모두 증가하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-011
  Scenario: delivery retry와 correction chain은 paid MVW를 중복시키지 않는다
    Given 동일 workflow와 terminal receipt에 delivery retry가 여러 개 있다
    And outcome chain에 ORIGINAL과 SUPERSEDING head가 있다
    When cutoff의 current head를 계산한다
    Then root_fact_id는 한 번만 세어야 한다
    And current head가 INVERSE이면 0을 세어야 한다

  # scenario-id: AC-BUSINESS_MODEL-012
  Scenario: first paid value는 data ready 이전으로 backdate되지 않는다
    Given eligible terminal outcome이 DATA_READY 이전에 있다
    When FIRST_PAID_VALUE를 평가한다
    Then 해당 outcome을 first paid value로 사용하지 않아야 한다
    And 누락된 순서 gate를 BLOCKED 또는 UNKNOWN으로 보여야 한다

  # scenario-id: AC-BUSINESS_MODEL-013
  Scenario: activation 7일과 P90 14일 clock이 동일 receipt를 쓴다
    Given DATA_READY와 FIRST_PAID_VALUE의 immutable effective_at이 있다
    When elapsed time이 7일 이하이다
    Then BM-ACTIVATION-7D-RATE numerator에 들어가야 한다
    When elapsed time이 7일 초과 14일 이하이다
    Then truthful activation은 기록하되 7일 numerator에는 들어가지 않아야 한다
    And BM-ACTIVATION-TTFPV-P90은 동일 interval을 사용해야 한다

  # scenario-id: AC-BUSINESS_MODEL-014
  Scenario: 미성숙 activation cohort는 denominator에 들어가지 않는다
    Given DATA_READY 후 7일이 지나지 않은 조직이 있다
    When BM-ACTIVATION-7D-RATE를 계산한다
    Then 해당 조직은 matured denominator에 들어가지 않아야 한다
    And pending cohort count로 보여야 한다

  # scenario-id: AC-BUSINESS_MODEL-015
  Scenario: retention은 days 29부터 56의 추가 workflow 두 개를 요구한다
    Given activation workflow가 한 개 있다
    And activation_at + 29일 이상 57일 미만에 distinct strict paid MVW 두 개가 있다
    And 평가 시 trailing 30일에 strict paid MVW가 하나 이상 있다
    When activation_at + 57일 이후 retention을 평가한다
    Then BM-RETENTION-D29-56-RATE numerator에 조직을 한 번 포함해야 한다
    And activation workflow 자체는 추가 두 개에 포함하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-016
  Scenario: inactivity는 at-risk이지 churn이 아니다
    Given current contract가 있고 trailing 30일 paid MVW가 없다
    But terminal contract state가 없다
    When relationship health를 평가한다
    Then 상태는 AT_RISK여야 한다
    And CHURNED로 추론하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-017
  Scenario: churn은 terminal contract와 immutable receipt를 요구한다
    Given ENDED 또는 CANCELLED contract period이고 active replacement가 없다
    And 동일 qualification episode에 active 또는 suspended replacement contract가 없다
    When BM-RETENTION-CHURN-RATE를 계산한다
    Then churn effective_at이 월 window에 있을 때만 numerator에 포함해야 한다

  # scenario-id: AC-BUSINESS_MODEL-018
  Scenario: 가격은 pinned tariff와 half-even 산술로 결정된다
    Given current tariff와 complete usage facts와 effective discount 및 accounting correction이 있다
    When monthly net charge를 계산한다
    Then workspace base contributor block processing storage API SLA line을 계약 formula대로 계산해야 한다
    And 모든 quantity와 amount는 ops.round_half_even_numeric_v1을 사용해야 한다
    And PostgreSQL round away-from-zero 또는 binary float를 사용하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-019
  Scenario: unknown usage는 0으로 청구되지 않는다
    Given usage window receipt의 measurement_state가 PARTIAL 또는 UNKNOWN이다
    When invoice를 생성하거나 reconcile한다
    Then 자동 charge line을 만들지 않아야 한다
    And unknown_usage_count와 blocker를 표시해야 한다
    And COMPLETE quantity 0과 구별해야 한다

  # scenario-id: AC-BUSINESS_MODEL-020
  Scenario: usage receipt부터 invoice membership까지 exactly once이다
    Given service period의 current COMPLETE usage facts가 있다
    When invoice membership을 reconcile한다
    Then 각 usage fact는 included quota 또는 overage membership에 정확히 한 번 있어야 한다
    And ZERO_USAGE와 INCLUDED_ALLOWANCE도 ops.invoice_usage_memberships current leaf를 가져야 하며 charge line은 없어야 한다
    And BILLED_OVERAGE membership만 동일 invoice의 exact charge line을 가져야 한다
    And 하나의 usage fact가 두 effective invoice line을 만들지 않아야 한다
    And line ordinal과 line-set digest와 header conservation이 일치해야 한다

  # scenario-id: AC-BUSINESS_MODEL-021
  Scenario: invoice membership gap은 revenue와 readiness를 막는다
    Given invoice header total은 맞지만 effective usage fact 하나의 membership이 없다
    When billing reconciliation과 revenue qualification을 계산한다
    Then BM-BILLING-RECONCILIATION-COVERAGE는 1이 아니어야 한다
    And invoice는 UNKNOWN 또는 BLOCKED여야 한다
    And 그 invoice로 revenue margin SKU readiness success를 주장하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-022
  Scenario: 계약과 invoice는 그 자체로 recognized revenue가 아니다
    Given binding contract amount와 reconciled invoice가 있다
    But valid ops.revenue_facts가 없다
    When BM-REVENUE-RECOGNIZED-KRW를 계산한다
    Then recognized revenue는 증가하지 않아야 한다
    And commitment와 invoice를 별도 상태로 보여야 한다

  # scenario-id: AC-BUSINESS_MODEL-023
  Scenario: missing cost는 healthy margin으로 보이지 않는다
    Given cost capture가 0.99 미만이거나 direct coverage가 1 미만이거나 total coverage가 0.95 미만이다
    When BM-MARGIN-VARIABLE-GROSS-RATE와 BM-MARGIN-CONTRIBUTION-KRW를 계산한다
    Then 두 metric은 UNKNOWN이어야 한다
    And missing 및 unallocated amount를 0으로 사용하지 않아야 한다
    And evidence privacy correction approval gate를 낮추지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-024
  Scenario: CAC는 privacy-safe organization receipt에만 결속된다
    Given SALES_CUSTOMER_ACQUISITION cost allocation이 있다
    When current non-reversed acquisition receipt의 organization campaign digest가 일치한다
    Then BM-CAC-KRW에 포함할 수 있어야 한다
    But raw lead contact query cookie address handle message가 metric source에 있으면 hard gate가 실패해야 한다

  # scenario-id: AC-BUSINESS_MODEL-025
  Scenario: CAC payback은 세 개의 완전한 contribution month를 요구한다
    Given valid CAC가 있다
    But complete contribution month가 두 개뿐이다
    When BM-CAC-PAYBACK-MONTHS를 계산한다
    Then 상태는 NOT_APPLICABLE이어야 한다
    And GA readiness evidence로 쓰지 않아야 한다
    When 세 달 average contribution이 0 이하이다
    Then status는 UNKNOWN이고 reasonCode는 NONPOSITIVE_CONTRIBUTION이며 value는 null이어야 한다
    And readiness는 실패해야 한다

  # scenario-id: AC-BUSINESS_MODEL-026
  Scenario: SLA telemetry gap은 green이 아니다
    Given SLA-selected contract와 target policy가 있다
    But required SLI receipt interval에 gap이 있다
    When BM-SLA-AVAILABILITY-RATE를 계산한다
    Then 상태는 UNKNOWN이어야 한다
    And telemetry-gap incident를 열어야 한다
    And SLA success를 주장하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-027
  Scenario: public-interest access는 무료로 유지된다
    Given public fact evidence locator revision correction response appeal privacy methodology source funding governance 또는 basic subscription flow가 있다
    When 고객 계약이 없거나 quota를 소진한다
    Then 사실 completeness와 해당 rights flow를 paywall로 막지 않아야 한다
    And content-neutral abuse control만 적용할 수 있어야 한다
    And 계약 만료 청구 실패 quota 소진 churn 또는 commercial hard stop은 private workspace 처리만 막을 수 있어야 한다
    And private ingestion batch analysis collaboration organization-only API channel SLA support receipt는 유료 계약 범위일 수 있어야 한다
    But 무료 public fact locator limitation counter-evidence correction response appeal privacy verification evidence를 trial metered preview 또는 entitlement로 취급하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-028
  Scenario: 수익성은 editorial 및 trust 우선순위를 변경하지 않는다
    Given 고객이 높은 revenue 또는 낮은 margin을 만든다
    When detection publication response correction privacy evidence approval을 평가한다
    Then 고객 revenue cost 또는 contract identity를 input으로 사용하지 않아야 한다
    And price quota efficiency support 또는 sale decision만 바꿀 수 있어야 한다

  # scenario-id: AC-BUSINESS_MODEL-029
  Scenario: confirmed trust breach는 즉시 commercial hard stop이다
    Given unauthorized customer-data reuse 또는 commercial editorial influence가 독립 검증되었다
    When continuation gate를 평가한다
    Then affected paid capability와 신규 sale 및 renewal을 중지해야 한다
    And evidence를 보존하고 incident와 trust owner를 기록해야 한다
    And growth metric이 이를 상쇄하지 못해야 한다

  # scenario-id: AC-BUSINESS_MODEL-030
  Scenario: 작은 cohort는 오해를 주는 rate를 만들지 않는다
    Given eligible organization이 4개 이하이다
    When activation retention 또는 pilot-to-paid metric을 표시한다
    Then count와 eligibility와 unknown count만 보여야 한다
    And percentage 또는 automated stop/scale verdict를 주장하지 않아야 한다
    And rate status는 NOT_APPLICABLE이고 reasonCode는 SAMPLE_TOO_SMALL이어야 한다
    When eligible organization이 5개 이상이다
    Then rate와 Wilson 95 percent interval을 함께 보여야 한다

  # scenario-id: AC-BUSINESS_MODEL-031
  Scenario: metric version과 input evidence는 모든 surface에서 같다
    Given 동일 as_of와 metric window가 있다
    When API와 OPS-004 UI와 export에서 metric을 읽는다
    Then metric ID version formula digest input-set digest status reasonCode freshness unknown reason count가 같아야 한다
    And correction은 새 input digest를 만들고 과거 receipt를 덮어쓰지 않아야 한다
    And paid-MVW-per-active-org의 numerator와 denominator는 동일 qualification cohort episode organization set SKU timezone window cutoff여야 한다
    And global 또는 cross-cohort MVW numerator나 cohort ratio 평균을 사용하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-032
  Scenario: business 화면은 10초 안에 현재 상태와 다음 행동을 설명한다
    Given budgets.manage actor가 OPS-004를 연다
    When BusinessHealthV1을 렌더링한다
    Then current commercial state와 가장 큰 breach 또는 unknown이 먼저 보여야 한다
    And paid MVW activation retention revenue margin evidence freshness owner 및 next action을 순서대로 찾아야 한다
    And UUID schema field raw JSON과 internal operation ID가 primary language이면 실패해야 한다

  # scenario-id: AC-BUSINESS_MODEL-033
  Scenario: business panel은 dashboard에서 accounting fact를 mutate하지 않는다
    Given INT-001 OPS-001 OPS-004 또는 AUD-001의 business panel이 있다
    When 사용자가 metric과 evidence를 조회하거나 export한다
    Then 조회와 export만 수행해야 한다
    And commercial editorial accounting mutation은 별도의 typed reviewed operation 및 exact approval receipt를 요구해야 한다

  # scenario-id: AC-BUSINESS_MODEL-034
  Scenario: stale partial error 상태가 known truth를 지우지 않는다
    Given business metric source 일부가 stale 또는 unavailable이다
    When screen을 렌더링한다
    Then known section은 cutoff와 함께 남겨야 한다
    And unknown source와 consequence와 owner를 prominent하게 보여야 한다
    And stale value를 green healthy로 표시하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-035
  Scenario: commercial pause는 cohort와 formula 변경으로 회피되지 않는다
    Given contract의 commercial_pause trigger가 충족되었다
    When pause review를 수행한다
    Then 신규 GA sale과 paid acquisition을 중지하고 기존 계약은 안전하게 이행해야 한다
    And formula cohort exclusion free boundary 또는 trust gate를 바꾸어 실패를 숨기지 않아야 한다
    And resume에는 dated corrective evidence와 독립 finance product SRE 승인이 있어야 한다

  # scenario-id: AC-BUSINESS_MODEL-036
  Scenario: business model hard gate는 fixture와 placeholder로 통과하지 않는다
    Given production business-model verification을 수행한다
    Then minimal qualification receipt와 deterministic stage read functions와 operation mapping과 화면 상태와 runtime evidence가 구현되어야 한다
    And fixture-only placeholder 501 skipped test analytics-only metric 또는 generic JSON은 실패해야 한다

  # scenario-id: AC-BUSINESS_MODEL-037
  Scenario: qualification 외 stage를 별도 ledger나 event로 저장하지 않는다
    Given current non-reversed minimal qualification receipt가 있다
    And contract activation readiness snapshot outcome invoice SLI의 immutable source facts가 있다
    When 동일 as_of formula version policy digest와 source snapshot으로 stage를 두 번 계산한다
    Then CONFIGURED DATA_READY FIRST_PAID_VALUE ACTIVATED RETAINED AT_RISK CHURNED 결과와 input digest가 byte-equivalent여야 한다
    And qualification 외 commercial stage row 또는 general stage event를 쓰지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-038
  Scenario: expansion eligibility는 두 달의 value demand economics trust를 모두 요구한다
    Given revenue-qualified organization에 complete billing month가 연속 두 개 있다
    And trailing 60일 demand와 paid MVW retention reconciliation margin support readiness SLA trust evidence가 모두 KNOWN이다
    When BM-EXPANSION-ELIGIBILITY-RATE를 동일 cutoff로 계산한다
    Then 모든 organization-level eligibility predicate를 통과한 조직만 ELIGIBLE이어야 한다
    And unknown predicate가 하나라도 있으면 aggregate status는 UNKNOWN이고 value는 null이어야 한다
    And ELIGIBLE이 아닌 조직에 quota seat SLA 또는 channel expansion을 자동 적용하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-039
  Scenario: renewal eligibility는 forward 60일 contract window와 trailing evidence를 결속한다
    Given ACTIVE 및 PROVISIONED contract period_end가 as_of 초과 60일 이내이다
    And trailing 90일 value retention과 두 complete month reconciliation margin support readiness SLA trust evidence가 있다
    When BM-RENEWAL-ELIGIBILITY-RATE를 동일 cutoff로 계산한다
    Then 모든 contract-level predicate를 통과한 root만 ELIGIBLE이어야 한다
    And unknown predicate가 하나라도 있으면 status는 UNKNOWN이고 value는 null이어야 한다
    And metric은 contract를 갱신하거나 revenue를 기록하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-040
  Scenario: 모든 metric은 breach action과 healthy NONE issue를 가진다
    Given business-model metric catalog를 읽는다
    Then 모든 metric에는 explicit breach_action과 healthy_issue_code NONE이 있어야 한다
    When required metric이 KNOWN이고 PASS 또는 정상 NOT_EVALUATED이며 readiness와 trust가 정상이다
    Then metric reasonCode issueCode breachAction과 top issueCode는 NONE이고 nextActionCode는 NO_ACTION_REQUIRED여야 한다
    When metric status가 UNKNOWN이거나 threshold가 BREACH이다
    Then issueCode는 NONE이면 안 되고 typed owner action이 있어야 한다
    And UNKNOWN은 null value와 non-NONE reasonCode를 가져야 하며 evidence 누락을 NOT_APPLICABLE로 바꾸지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-041
  Scenario: additive review feature는 실행 mapping 없이는 release gate가 아니다
    Given 이 feature는 @additive-review이고 contract status는 REVIEW_REQUIRED이다
    When supplemental acceptance registry를 검증한다
    Then 48개 scenario ID 각각 tests/acceptance/supplemental-executable-mapping.yaml에 정확히 한 번 있어야 한다
    And 각 mapping은 skip_policy FORBIDDEN과 실제 implementation path와 executing command를 가져야 한다
    And invoice membership SLA revenue overlap unattributed CAC API runtime blocker가 하나라도 OPEN이면 final release tag 또는 LGTM으로 승격하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-042
  Scenario: economics cash tax import는 typed 승인 executor와 최소 DB 권한만 사용한다
    Given ECONOMICS_IMPORT action과 private.ExecuteEconomicsImport executor에 11개 closed operation이 선언되어 있다
    And executor database role은 gurine_economics_importer이고 payment runtime role은 gurine_billing_gateway이다
    When 제안과 독립 검토와 STEP_UP execution authorization을 거쳐 typed import를 실행한다
    Then economics 24개 relation과 R6e 신규 7개 relation에 대한 모든 runtime role의 direct INSERT UPDATE DELETE 권한은 없어야 한다
    And ops.action_approval_economics_import_details ops.cash_application_facts ops.tax_invoice_issuance_receipts ops.payment_method_bindings ops.payment_charge_attempts ops.provider_webhook_receipts ops.donation_facts만 exact owner boundary로 기록되어야 한다
    And cash application과 tax invoice receipt는 exact invoice digest와 predecessor fence와 source evidence digest에 결속되어야 한다
    And fresh success는 immutable receipt audit outbox를 하나씩 만들고 exact replay는 추가 effect를 만들지 않아야 한다
    But generic relation name untyped JSON dummy digest UNKNOWN usage 또는 승인 전 owner 호출은 모두 zero-write로 거부되어야 한다

  # scenario-id: AC-BUSINESS_MODEL-043
  Scenario: 첫 tariff는 승인된 원가 close 뒤에서만 6000 또는 7000 margin gate를 통과한다
    Given production authority가 아닌 TEST_FIXTURE_ONLY 원가 import evidence로 첫 cost allocation close를 검증한다
    When current PERIOD close와 line-set digest와 capture direct total coverage evidence가 없거나 불일치한다
    Then tariff version은 생성되지 않고 tariff receipt audit outbox도 증가하지 않아야 한다
    When PILOT tariff의 공식 projected variable gross margin이 6000 basis points 미만이거나 GA가 7000 basis points 미만이다
    Then 기존 tariff_required_margin_ck tariff_cost_evidence_threshold_ck tariff_margin_formula_ck tariff_margin_exception_ck가 이를 거부해야 한다
    And PILOT exception을 GA에 재사용하거나 caller가 계산값을 바꾸어 CHECK를 우회하지 않아야 한다
    But exact close evidence와 공식 half-even 계산을 만족한 경계값은 동일 typed owner 경로에서만 기록되어야 한다

  # scenario-id: AC-BUSINESS_MODEL-044
  Scenario: donation test fixture는 production 결제나 entitlement 권위가 아니다
    Given 승인된 production donation offer와 merchant key와 durable billing-key vault와 provider activation evidence가 없다
    And test adapter offer의 authority는 TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY이고 production_readiness_effect는 NONE이다
    When production donation availability와 public access와 investigation priority를 평가한다
    Then production donation action은 UNAVAILABLE이어야 하고 test fixture 금액 또는 billing key를 production authority로 사용하지 않아야 한다
    And 후원은 접근권이 아니며 조사 면제가 아니라는 고지를 유지해야 한다
    And donation payment status는 contract capability detection publication correction response 또는 공개 접근을 변경하지 않아야 한다
    But 공개 사실 근거 정정 응답권 기본 구독과 합리적 공개 API는 결제 상태와 무관하게 무료여야 한다

  # scenario-id: AC-BUSINESS_MODEL-045
  Scenario: webhook은 검증과 unique claim 뒤 provider 재조회로만 확정된다
    Given TossPayments KakaoPay Stripe adapter는 merchant-scheduled이고 authenticated fetch를 payment truth로 선언한다
    When provider가 지원하는 webhook signature를 검증하고 provider event identity를 unique claim한 뒤 fetch_payment를 호출한다
    Then webhook hint와 fetch 결과가 다르면 fetch 결과만 charge와 donation truth가 되어야 한다
    And signature 미지원은 VERIFIED로 기록하지 않되 authenticated fetch를 생략하지 않아야 한다
    And 동일 provider event identity와 body digest replay는 stored receipt를 반환하고 provider fetch charge donation을 중복하지 않아야 한다
    And 동일 provider event identity의 다른 body digest는 typed conflict로 zero-write 처리되어야 한다
    But invalid signature unknown fetch 또는 reconciliation-required 결과는 donation fact를 만들지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-046
  Scenario: payment failure는 review task만 만들고 계약이나 공개 접근을 자동 변경하지 않는다
    Given authenticated provider fetch 또는 signed collection evidence가 payment failure를 확정한다
    When billing-gateway 또는 approved economics executor가 failure receipt를 기록한다
    Then immutable failure attempt와 payment review task와 notification.payment_review_requested.v1 event만 한 번 생성되어야 한다
    And current commercial contract period offer capability activation decision과 public projection digest는 바뀌지 않아야 한다
    And replay는 task audit outbox를 중복하지 않고 changed replay는 conflict여야 한다
    But suspension은 별도 human proposal independent review STEP_UP 승인 뒤 REPLACEMENT contract period로만 가능해야 한다
    And failure 또는 suspension 뒤에도 anonymous public facts와 PUB-023와 public API 접근은 동일하게 유지되어야 한다

  # scenario-id: AC-BUSINESS_MODEL-047
  Scenario: donation은 candidate와 독립 disclosure 승인 뒤에만 PUB-023에 공개된다
    Given authenticated fetch와 successful charge에 결속된 immutable donation fact가 있다
    When donation.fact_recorded.v1을 projection-worker가 exact source digest로 소비한다
    Then private funding snapshot candidate만 하나 만들고 editorial revision 또는 public transparency report를 직접 만들지 않아야 한다
    When FUNDING_DISCLOSURE proposal과 independent review와 publication execution이 exact snapshot digest를 승인한다
    Then governance.funding_disclosure_published.v1 뒤 최신 signed disclosure만 PUB-023에 나타나야 한다
    And downloadTransparencyReport GET /v1/transparency-reports/{reportId}/download는 JSON 또는 CSV bytes와 source revision digest를 결속해야 한다
    And raw donor identity billing key provider payload private amount와 internal actor ID는 공개 report에 없어야 한다
    But signed disclosure가 없으면 값을 발명하지 않고 UNKNOWN과 다운로드 unavailable을 보여야 한다
    And denominator evidence가 없으면 독립 승인된 signed UNKNOWN revision과 report를 다운로드 가능하게 유지하되 concentration 값을 발명하지 않아야 한다

  # scenario-id: AC-BUSINESS_MODEL-048
  Scenario Outline: R6e의 두 신규 event payload는 닫힌 source-bound oracle이다
    Given R6e event type이 <event_type>이고 producer set은 <producers>이며 operation set은 <producer_operations>이고 consumer set은 <consumers>이다
    When canonical addendum event payload schema와 producer consumer binding을 구조적으로 검증한다
    Then required와 property field set은 모두 <required_fields>와 정확히 같고 additionalProperties는 false여야 한다
    And 각 field의 type format ref enum minimum은 canonical schema와 정확히 같아야 한다
    And producer sourceKind binding set은 <producer_bindings>와 정확히 같아야 한다
    And raw credential webhook body donor identity customer identity와 caller-authored effect digest는 포함하지 않아야 한다
    And <effect_boundary>를 강제하고 exact replay는 effect를 중복하지 않아야 한다

    Examples:
      | event_type                               | producers                                                   | producer_operations                                                | consumers           | producer_bindings                                                                                                              | required_fields                                                                                                                        | effect_boundary                                                                                     |
      | donation.fact_recorded.v1                | billing-gateway                                             | private.ExecuteDonationCharge,private.ReceivePaymentWebhook         | funding-projector   | NONE                                                                                                                           | donationFactId,donationFactDigest,chargeAttemptId,chargeAttemptDigest,providerFetchDigest,occurredAt                                  | exact donation and charge source lookup 뒤 private funding snapshot candidate만 생성한다            |
      | notification.payment_review_requested.v1 | billing-gateway,workflow-worker.economics-import-executor   | private.ReceivePaymentWebhook,private.ExecuteEconomicsImport       | notification-worker | billing-gateway:DONATION_PAYMENT_FAILURE,workflow-worker.economics-import-executor:SIGNED_COLLECTION_FAILURE                   | reviewTaskId,reviewTaskVersion,reviewTaskDigest,sourceKind,sourceReceiptId,sourceReceiptDigest,occurredAt                              | DONATION_PAYMENT_FAILURE 또는 SIGNED_COLLECTION_FAILURE review task만 notification-worker에 전달한다 |
