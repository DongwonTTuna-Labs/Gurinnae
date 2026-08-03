# 고객 1호 수동 경제 원장 반입 절차

<!-- markdownlint-disable MD013 -->

상태: **REVIEW_REQUIRED — production importer 실행은 현재 UNAVAILABLE, FINAL ABI와 운영 명령은 OPEN**

이 문서는 `EVIDENCE_WORKSPACE_ORGANIZATION_V1` 고객 1호를 qualification부터 첫 비용
마감, tariff, 계약, 사용량, invoice, revenue, cash, tax 증빙까지 연결하는 운영 절차다. 이
문서 자체는 production 반입 승인이나 live provider acceptance가 아니다. 권위는
[`business-model-contract.yaml`](../../specs/product/business-model-contract.yaml), 물리 원장
형태는 [`0029_product_economics.sql`](../../db/migrations/0029_product_economics.sql)과
[`0041_r6e_monetization_runtime.sql`](../../db/migrations/0041_r6e_monetization_runtime.sql), 승인 수명주기는
[`addendum-operation-contracts.yaml`](../../specs/product/addendum-operation-contracts.yaml)에
있다. 문서와 현재 source가 충돌하면 source와 권위 계약을 다시 확인하고 실행을 중단한다.

## 1. 절대 경계

- 경제 사실은 `ECONOMICS_IMPORT` ActionProposal의 독립 검토와 현재 STEP_UP 승인 뒤에만
  workflow-worker의 economics-import executor가 전용 `gurine_economics_importer` DB
  credential로 typed owner boundary에 추가한다. 운영자는 표에 직접 `INSERT`, `UPDATE`,
  `DELETE`하거나 generic JSON writer, `_legacy_` writer, migration owner 계정으로 우회하지
  않는다.
- proposer는 `actions.propose`와 `budgets.manage`, counted reviewer는 `actions.review`와
  `budgets.manage`가 필요하다. 둘은 서로 다른 사람이어야 한다. 실행자는 승인된 exact
  `private.ExecuteEconomicsImport`와 `economics.import` 경계뿐이다. billing-gateway는
  payment-only이며 경제 사실을 제안·검토·실행·반입하거나 원장에 직접 쓸 수 없다.
- 동일한 경제 사실은 invoice, revenue, cash, tax, cost, paid value 중 하나만 증명한다.
  한 사실에서 다른 사실을 추론하거나 누락값을 `0`, 성공, paid, issued로 보정하지 않는다.
- 고객 1호 B2B 경로는 서명된 서면 계약, 외부 전자세금계산서 발행 확인, 외부
  `BANK_TRANSFER` 증빙의 signed typed import뿐이다. 계약에 남아 있는 `PG_SETTLEMENT` 종류는
  별도로 승인된 외부 회계 증빙을 수동 반입하는 경계일 뿐이며 고객 1호 결제 수단이나 fallback이
  아니다. self-service checkout, 카드 결제 실행, receivable mutation, 상용 payment API, live PG,
  live ASP가 없다.
- 후원 결제는 B2B 판매와 분리된 `TEST_MODE_ONLY` 경계다. fixture adapter 결과는 SKU,
  계약, invoice, revenue, cash, entitlement, production readiness를 만들지 않는다. 허용되는
  webhook은 test 환경의 인증된 deterministic internal fixture ingress뿐이며 live/public provider
  webhook은 비활성이다.
- dunning은 명시적인 signed collection-failure 증빙이 있을 때 운영자 task/notification만
  만든다. 미입금의 부재, 시간 경과, 누락 webhook을 실패로 추론하지 않는다.
- 계약, invoice, quota, 후원, dunning 상태는 공개 사실·근거·정정·응답·이의제기·개인정보·
  접근성·기본 구독·합리적인 public API/export 접근을 제거하거나 지연시키지 못한다.
- 원문 계약, 계좌, 담당자, billing key, provider payload, webhook body/signature, raw 식별자는
  runbook evidence, 로그, 오류, ticket에 복사하지 않는다. 승인된 digest, HMAC, UUID,
  redacted receipt만 사용한다.

## 2. 현재 실행 가능성 확인

### 2.1 Provision-first role gate

R6e 역할은 migration이 만들거나 보정하는 애플리케이션 데이터가 아니다. checksummed
control-plane 입력인
[`r6e-role-provisioning.sql`](../../db/control-plane/r6e-role-provisioning.sql),
[`r6e-role-provisioning.sha256`](../../db/control-plane/r6e-role-provisioning.sha256),
[`provision-r6e-roles.sh`](../../infra/scripts/provision-r6e-roles.sh)만 역할 집합을 provision한다.
SQL 파일을 `psql`로 직접 호출하거나 migration/runtime 계정으로 역할을 만들지 않는다.

Wrapper는 SQL manifest를 먼저 검증하고 현재 `0041` migration의 SHA-384를 계산해 control-plane
transaction에 전달한다. 문서에 checksum literal을 복사하지 않는다. source가 바뀌면 manifest와
wrapper 검증이 source truth이며, 불일치는 실행 전 실패해야 한다.

| role | LOGIN | INHERIT | connection limit | 용도 |
| --- | --- | --- | --- | --- |
| `gurine_economics_writer` | 아니요 | 아니요 | -1 | economics owner function 소유자 |
| `gurine_payment_writer` | 아니요 | 아니요 | -1 | payment owner function 소유자 |
| `gurine_billing_gateway` | 예 | 아니요 | 8 | payment-only runtime caller |
| `gurine_economics_importer` | 예 | 아니요 | 4 | approved economics import runtime caller |

네 역할은 모두 non-superuser, non-createdb, non-createrole, non-replication, non-bypass-RLS이고
password, role setting, membership, 다른 DB authority가 없어야 한다. `LOGIN` 역할도 password는
`NULL`이며 운영자 소유 client-certificate, peer 또는 IAM 인증만 사용한다. runtime/migrator URL과
역할 provisioner URL 또는 actor를 공유하지 않는다.

실행 순서는 다음 gate를 건너뛰지 않는다.

1. `ROLE_PROVISIONER_DATABASE_URL`은 runtime/migrator와 분리된 exact superuser 세션이어야 한다.
2. `ROLE_PROVISIONER_EXPECTED_ACTOR`는 같은 unquoted `session_user=current_user`여야 한다.
3. checksummed role provisioner가 성공한 뒤에만 migrator가 `0041`을 적용한다.
4. migration ledger의 exact `0041` checksum과
   `ops.assert_r6e_runtime_role_postconditions_v1()`이 모두 참이어야 runtime을 시작한다.
5. partial role set, attribute drift, membership, cross-database authority, checksum/ledger/oracle 불일치는
   자동 수리하지 않고 `R6E_*` safe code로 중단한다.

현재 FINAL post-`0041` oracle과 derived marker manifest가 확정됐다는 증거가 이 문서에 아직 없다.
따라서 위 파일 경로는 검토 인벤토리이지 복사 가능한 production 명령이 아니다. FINAL 신호 전에는
수동 실행 예시나 환경변수 예시 값을 만들지 않는다.

### 2.2 Operator-owned DB authentication gate

`PASSWORD NULL`은 PostgreSQL catalog에 공유 비밀번호가 없다는 뜻이지, `LOGIN` 역할의 실제
인증 경로가 provision됐다는 뜻이 아니다. Role provisioner는 역할 속성과 권한 경계만 고정한다.
실제 DB 인증은 배포 운영자가 소유하는 선행조건이며, exact 역할에 매핑된 client certificate,
managed IAM, peer 또는 동등한 외부 인증과 그 발급·회전·폐기·감사 절차가 필요하다. 저장소에는
모든 production/TEST_ONLY 배포에 그대로 적용할 인증 공급·mount 계약이 아직 없으므로, 이
문서는 DB URL, password, certificate 경로, 서명값 또는 공급 명령을 추측하지 않는다.

활성화할 runtime이 실제 사용하는 연결과 pool에서 작업 전에 다음 exact session probe 결과를
각각 얻어야 한다.

| runtime | 필수 `session_user` | 필수 `current_user` |
| --- | --- | --- |
| billing-gateway | `gurine_billing_gateway` | `gurine_billing_gateway` |
| workflow-worker economics importer | `gurine_economics_importer` | `gurine_economics_importer` |

URL userinfo, preflight 문자열 검사, 역할 존재 확인은 이 probe를 대신하지 않는다. shared bootstrap,
provisioner, migrator 또는 일반 workflow credential로 접속한 뒤 `SET ROLE`로 전환하지 않는다.
password를 source, Compose 기본값, command, log 또는 evidence에 넣어 `PASSWORD NULL` 경계를
우회하지 않는다. 외부 인증 공급과 위 실제 session 결과가 없으면 enabled `TEST_ONLY`와 production
runtime은 `UNAVAILABLE`이다. 인증 gate 통과도 FINAL owner ABI, ACL, fixture 또는 live-provider
gate를 대신하지 않는다.

현재 economics pool은 nonempty `ECONOMICS_DATABASE_URL`에 대해 접속 직후
`session_user=current_user=gurine_economics_importer`를 검증하고 mismatch를 startup failure로
처리한다. URL이 비어 있으면 economics pool을 만들지 않으며 `ECONOMICS_IMPORT` execution만
retryable `ECONOMICS_OWNER_ABI_UNAVAILABLE`로 fail-closed한다. 일반 workflow-worker 작업은 계속
처리된다. 이 분리는 owner ABI latch가 나중에 활성화된 뒤에도 유지해야 한다. 반면 현재
billing-gateway는 exact session probe와 PostgreSQL payment store의 runtime 증거가 없고
`TEST_ONLY` 시작 자체가 차단돼 있으므로 인증값만 공급해 활성화하지 않는다.

### 2.3 Action lifecycle inventory

현재 source에서 다음 Control API operation 경로는 확인된다. 아래는 route 인벤토리이며
복사 가능한 운영 명령이 아니다. Actor Assertion은 method, path, body, content type,
`Idempotency-Key`, capability, assurance에 request-bound이므로 임의 `curl`이나 재사용 token을
만들면 안 된다.

| 단계 | operation | 경로 |
| --- | --- | --- |
| 제안 생성 | `createActionProposal` | `POST /v1/internal/action-proposals` |
| exact draft preview | `previewActionDraft` | `POST /v1/internal/action-proposals/{proposalId}:preview` |
| 검토 요청 | `submitActionForReview` | `POST /v1/internal/action-proposals/{proposalId}:submit-review` |
| 독립 검토 claim | `claimActionReview` | `POST /v1/internal/action-proposals/{proposalId}:claim-review` |
| STEP_UP 승인 | `submitActionDecision` | `POST /v1/internal/action-proposals/{proposalId}:decide` |
| 실행 영수증 조회 | `getActionExecutionReceipt` | `GET /v1/internal/action-executions/{executionId}/receipt` |

승인 경로의 고정값은 action kind `ECONOMICS_IMPORT`, target command
`private.ExecuteEconomicsImport`, effect owner/caller
`workflow-worker.economics-import-executor`, DB principal `gurine_economics_importer`다. 이
binding이 하나라도 다르거나 billing-gateway credential을 재사용하면 실행하지 않는다.

Closed typed import 종류는 정확히 다음 11개다. 이 목록 밖의 relation 이름, generic CRUD,
free-form map은 허용하지 않는다.

1. `recordCommercialQualification`
2. `importCostAllocationClose`
3. `createTariffVersion`
4. `recordCommercialContractPeriod`
5. `recordUsageWindow`
6. `recordInvoice`
7. `recordRevenue`
8. `recordAccountingCorrection`
9. `recordCashApplication`
10. `recordTaxInvoiceIssuance`
11. `recordCollectionFailure`

Production에서 이 수명주기를 끝까지 호출하는 검증된 operator CLI/UI command set과 최종
owner-function ABI는 아직 이 문서의 current-source proof에 포함되지 않았다. 따라서 §4의
단계를 payload 작성 체크리스트로 사용하되, `OPEN_QUESTIONS`가 닫히기 전에는 production
호출을 하지 않는다.

## 3. 실행 전 준비

한 번의 import마다 다음을 별도 evidence manifest에 고정한다.

1. environment, deployment ID, organization ID, SKU, accounting timezone, reporting currency
2. operation 종류와 exact source row/receipt version, source signature digest, evidence-set digest
3. 정책·공식·schema version과 그 digest, `asOf`, effective interval
4. predecessor/root/version/digest 또는 ORIGINAL임을 증명하는 빈 predecessor 상태
5. proposer, 독립 reviewer, backup operator의 role/capability 증빙과 현재 conflict/recusal 상태
6. request별 새 idempotency identity, expected version/content/approval digest
7. rollback이 아니라 append-only correction으로 복구할 owner와 reconciliation 기한

다음 중 하나면 제안을 만들지 않는다.

- source receipt나 signature가 없거나 만료·불일치·중복·부분 상태다.
- expected predecessor/head, policy, timezone, currency, service interval을 하나로 고정할 수 없다.
- 실제 값 대신 test fixture, 예시 가격, dummy digest, 임의 `0`, 최신값 join을 사용해야 한다.
- proposer와 counted reviewer를 분리할 수 없거나 STEP_UP action context를 만들 수 없다.
- 실행 뒤 필요한 외부 정정/반전 또는 운영 책임자가 정해지지 않았다.

### 3.1 Production live go/no-go

다음 항목을 모두 같은 배포 digest와 evidence cutoff에서 확인하지 못하면 live 반입은 `NO-GO`다.

- checksummed role provisioner, exact migration row, postcondition oracle가 성공하고 economics importer
  credential이 billing-gateway, migrator, role provisioner와 분리돼 있다.
- operator-owned client certificate, managed IAM, peer 또는 동등한 외부 DB 인증이 실제 배포에
  공급됐고 runtime pool의 probe가 billing은
  `session_user=current_user=gurine_billing_gateway`, economics는
  `session_user=current_user=gurine_economics_importer`임을 증명한다. shared bootstrap credential,
  `SET ROLE`, source 안의 password는 모두 없어야 한다.
- economics import를 활성화하는 배포에는 전용 `ECONOMICS_DATABASE_URL`과 위 probe 증거가 있어야
  한다. URL이 비어 있으면 economics import의 live 판정만 `NO-GO`로 유지하고, 일반
  workflow-worker 처리를 함께 중단하거나 shared DB pool로 대체하지 않는다.
- 배포된 owner-function ABI와 operator UI/CLI가 current generated contract와 같고, request-bound
  Actor Assertion 및 전체 receipt 조회가 실제 환경에서 검증됐다.
- proposer, counted reviewer, backup operator가 현재 capability, STEP_UP, recusal/분리 증빙을 갖는다.
- qualification, cost source/category/FX/correction, 서면 계약/offer, usage, performance,
  `BANK_TRANSFER`, 외부 전자세금계산서 acknowledgement의 source system, 서명 형식, 보존 책임자가
  확정됐다.
- 첫 production 수치와 정책은 실제 signed evidence에서 왔으며 TEST fixture, template, 예시 값,
  임의 digest를 사용하지 않는다.
- 동일 execution 조회, restart, timeout, stale fence, exact replay, changed-digest conflict,
  reconciliation과 append-only correction의 담당자·기한이 live smoke에서 검증됐다.
- live PG/ASP, checkout, 카드 결제, provider webhook, donation-to-invoice 경로는 비활성이고 해당
  credential/endpoint가 배포되지 않았다.

Preflight나 local test의 PASS 하나만으로 위 항목을 합성하지 않는다. 항목별 원 receipt와 조회
시각을 evidence manifest에 남긴다.

## 4. 모든 typed import의 공통 승인 절차

### 4.1 제안 생성

`createActionProposal`에 `actionKind=ECONOMICS_IMPORT`와 하나의 closed typed operation만
제출한다. `origin`, `draft`, `rationale`, `expiresAt`을 exact source evidence에 묶는다. 금액,
가격, cash 상태 또는 target relation 이름을 untyped JSON으로 추가하지 않는다. 제안 receipt의
`proposalId`, version, content/approval digest와 idempotency receipt를 보존한다.

### 4.2 Preview

같은 `proposalId`, expected version, expected content digest로 preview한다. preview가 반환한
정규화 operation, target binding, source evidence set, 정책 digest, 예상 effect를 원 source와
독립적으로 대조한다. preview ID/digest가 없거나 stale이면 검토로 보내지 않는다. draft가
변경되면 이전 preview를 폐기하고 새 version을 다시 preview한다.

### 4.3 독립 검토

preview ID/digest로 `submitActionForReview`를 실행하고 생성된 assignment를 proposer가 아닌
reviewer가 `claimActionReview`로 claim한다. reviewer는 다음을 확인한다.

- typed variant와 source evidence가 하나의 경제 authority만 변경한다.
- predecessor, interval, currency, organization, contract/tariff/invoice binding이 exact하다.
- fixture/test marker가 production authority에 섞이지 않았다.
- replay identity, failure path, correction plan, public-access no-effect가 명시됐다.
- 본인이 proposer, source signer와 필요한 분리 의무를 위반하지 않는다.

불일치가 있으면 `CHANGES_REQUIRED` 또는 `REJECT`한다. 운영 편의를 이유로 preview나 독립
검토를 생략하지 않는다.

### 4.4 STEP_UP 승인

`APPROVE`는 exact proposal version, assignment version, approval digest, action-bound STEP_UP
Actor Assertion으로만 제출한다. UI의 파괴 확인창, 최근 로그인, 역할 이름만으로 STEP_UP을
추론하지 않는다. 승인 receipt가 만든 `executionId`, generation, execution/approval/counting
digest를 기록한다.

### 4.5 Workflow worker 실행과 receipt

Workflow-worker의 economics-import executor는 현재 authorization을 claim한 뒤 fence와 request
digest를 재검증하고, 전용 importer pool로 typed owner function을 호출하고, 결과 receipt를
complete한다. 운영자가 job을 직접 삽입하거나 owner function을 SQL로 호출하지 않는다.
Billing-gateway는 이 단계에 참여하지 않는다.

같은 `executionId`로 receipt chain을 조회해 다음 값이 서로 일치할 때만 성공으로 판정한다.

- action kind, execution ID/generation, execution digest
- approval digest와 counted decision receipt-set digest
- effect idempotency key digest와 target binding digest
- effect receipt ID/digest와 resulting object ID/version/digest
- terminal state `SUCCEEDED`와 occurred-at, `reconciliationRequired=false`

HTTP 성공, queue ack, worker log, outbox row, invoice ID 하나만으로 성공을 판정하지 않는다.
receipt가 `PARTIALLY_SUCCEEDED`, `PERMANENT_FAILED`, `RECONCILIATION_REQUIRED`, incomplete,
in-progress 또는 unknown이면 다음 사업 단계로 진행하지 않는다.

## 5. 고객 1호 부트스트랩 순서

### 5.1 Qualification

`recordCommercialQualification` ORIGINAL을 먼저 제안한다.

- 정확히 13개 qualification criterion이 같은 current policy 아래 모두 `true`여야 한다.
- economic buyer, operational owner, independent reviewer, source-rights owner, incident/support
  owner의 primary/backup HMAC binding을 모두 제공하고 각 기능 안에서 두 사람이 달라야 한다.
- action 시점의 proposer/reviewer 독립성은 qualification role 배정과 별도로 다시 증명한다.
- acquisition source ID/digest는 둘 다 유효하거나 둘 다 null이어야 한다. null은 qualification을
  막지 않지만 attribution, CAC, payback을 `UNKNOWN`으로 유지한다.
- ORIGINAL은 새 qualification episode와 `firstQualifiedAt`을 만든다. role/source 정정은 같은
  episode의 REPLACEMENT, reversal 뒤 재qualification은 새 episode로 처리한다.

Qualification receipt가 terminal success이고 current non-reversed head임을 확인하기 전에는
tariff나 contract를 만들지 않는다.

### 5.2 첫 cost close

`importCostAllocationClose`는 하나의 deployment, 반개구간 회계 기간, currency, timezone,
cost-policy version/digest에 대해 PERIOD header와 완전한 ordered LINE set을 함께 닫는다.

Production evidence는 해당 기간의 provider, infrastructure, payroll/time, legal/security,
support, internal-allocation source registry와 다음 12 category의 source/category matrix를 모두
포함한다.

`COMPUTE`, `DATABASE_WAL_BACKUP`, `STORAGE`, `EGRESS`, `MODEL_OCR`, `SEARCH`, `DELIVERY`,
`OBSERVABILITY`, `SUPPORT`, `HUMAN_REVIEW`, `LEGAL_SECURITY`,
`SALES_CUSTOMER_ACQUISITION`

각 cell은 `COMPLETE`, signed `NO_ACTIVITY_WITH_PROOF`, 또는 `UNKNOWN`으로 한 번만 나타난다.
누락·지연·부분·중복·서명 없음은 생략하지 않고 `UNKNOWN`이다. exact margin을 위한 close는
다음을 모두 만족해야 한다.

- `costCaptureState=MEASURED`; tariff에 사용할 production close는
  `claimState=ELIGIBLE`. 증명된 `NO_ACTIVITY`는 truthful close일 수 있지만 tariff 권위는 아님
- event coverage 0.99 이상, direct amount coverage 정확히 1, total amount coverage 0.95 이상
- source, pool, driver, correction, allocation set digest와 필요한 FX fact가 완전함
- captured amount = attributed amount + unallocated amount
- close receipt ID/digest와 closed-at가 존재함
- line별 source identity/amount, target, driver, allocation, rounding, record digest가 보존됨

`UNKNOWN`이나 positive unallocated amount는 0으로 만들지 않는다. 불완전 기간은 truthful
UNKNOWN으로 저장할 수 있지만 tariff, exact margin, cost-per-value, CAC/payback, expansion,
renewal 권위가 아니다. positive unallocated amount도 healthy margin claim을 차단한다.

#### TEST와 production 증거 경계

| 항목 | TEST fixture | production |
| --- | --- | --- |
| 목적 | schema, digest, replay, conflict, margin gate 검증 | 실제 고객 기간의 회계 authority |
| 격리 | ephemeral test DB, `TEST_FIXTURE` marker | production deployment와 실제 회계 기간 |
| 값 | 테스트가 생성한 합성 amount/ID/digest | signed source receipt에서 산출한 실제 amount/ID/digest |
| 사용 가능 범위 | 테스트 assertion과 fixture receipt | tariff, contract, readiness, 고객 원장 |
| 금지 | production으로 복사, readiness 충족, 가격 근거 | fixture fallback, dummy digest, 예시 금액 재사용 |

테스트 fixture의 기간, 금액, coverage, margin 수치는 production authority가 아니다. 테스트가
PASS해도 production first cost close가 완료된 것이 아니며, 실제 source/category/FX/correction
증빙으로 별도 close receipt를 받아야 한다.

#### 수동 signed typed TEST_FIXTURE 부트스트랩

이 부트스트랩은 manual economics import의 schema, digest, proposal/review/execution, replay와 tariff
fence를 증명하기 위한 테스트 절차다. 대상은 이름까지 고정된 disposable ephemeral DB이며 마지막에
rollback/폐기한다. production DB, 공유 개발 DB, production identity 또는 production source
receipt를 사용하지 않는다.

최종 fixture가 제공해야 하는 순서는 다음과 같다.

1. checksummed provisioner로 네 역할을 먼저 만들고 정확한 migration inventory를 순서대로 적용한다.
2. fixture가 선언한 `TEST_FIXTURE` authority의 signed typed cost source/category/FX/correction set만
   사용해 `importCostAllocationClose` 제안을 만든다. 문서 작성자가 amount, UUID, signature 또는
   digest를 채우지 않는다.
3. 제안자와 다른 fixture reviewer가 exact preview/content/approval digest를 독립 검토하고
   action-bound STEP_UP 결정으로 하나의 execution을 승인한다.
4. Workflow-worker economics importer가 typed owner boundary로 PERIOD header와 완전한 ordered LINE
   set을 함께 닫고, DB-derived row/allocation/close digest와 effect receipt를 반환해야 한다.
5. same identity/same digest는 저장된 receipt replay, same identity/changed digest는 conflict여야 한다.
   누락·부분·`UNKNOWN`·stale close 또는 digest mismatch는 tariff 생성을 차단해야 한다.
6. exact eligible close를 묶은 TEST tariff positive case와 cost evidence가 닫히지 않은 negative case를
   모두 확인하되 어떤 TEST 결과도 production price/readiness/customer ledger로 승격하지 않는다.
7. ambiguity case는 새 proposal/idempotency key로 재전송하지 않고 같은 execution과 resulting head를
   reconcile한 뒤 fixture transaction과 ephemeral DB를 폐기한다.

현재
[`r6e-monetization-runtime.sql`](../../db/test-fixtures/r6e-monetization-runtime.sql)의 economics
fixture marker와 최종 owner ABI가 완료됐다는 증거가 없다. 따라서
[`test-r6e-monetization-runtime.sh`](../../scripts/test-r6e-monetization-runtime.sh)는 현재
`owner-abi-not-final`로 중단돼야 한다. 다른 runtime 검증의 PASS를 cost-close 부트스트랩 PASS로
해석하지 않으며, FINAL fixture가 착지하기 전에는 이 문서에 실행 command, 함수 signature,
fixture 값 또는 expected digest를 추가하지 않는다.

이 스크립트가 FINAL gate 뒤 disposable loopback PostgreSQL에서 사용하는 `trust`와 ephemeral
runtime role의 임시 `LOGIN` 속성 변경은 격리된 개발/TEST fixture 증거일 뿐이다. 현재 `PENDING`
marker에서는 컨테이너 시작 전 중단하며, 나중에 fixture가 PASS해도 staging/production의 client
certificate, managed IAM, peer 또는 동등한 외부 인증을 증명하지 않는다. `trust` 설정이나 임시
role 변경을 공유 개발, staging 또는 production에 복사하지 않는다.

### 5.3 Tariff gate

`createTariffVersion`은 §5.2의 exact current cost PERIOD row와 record/allocation/close-receipt
digest를 묶는다. tariff가 service interval 전체를 덮고 SKU, KRW, accounting timezone이 계약과
같아야 한다.

- stage는 operator flag, 날짜, 고객 수, revenue, route, current tariff label로 선택하지 않는다.
  첫 current paid-workspace contract부터 current non-reversed GA readiness가 READY가 되기 전까지만
  PILOT이다. GA readiness가 한 번 적용된 뒤 만료·block되면 UNKNOWN/BLOCKED이며 낮은 PILOT
  target으로 되돌아가지 않는다.
- PILOT required P75 variable gross margin은 6000 basis points, GENERAL_AVAILABILITY는 7000이다.
- P75 variable cost는 `COMPUTE`부터 `LEGAL_SECURITY`까지 §5.2의 앞 11개 variable category만
  사용한다. `SALES_CUSTOMER_ACQUISITION`은 cost close matrix에는 남지만 CAC 전용이며 variable
  gross margin 분자에서 더하거나 빼지 않는다.
- projected basis points는 `(p75Revenue - p75VariableCost) / p75Revenue * 10000`의
  half-even 결과와 같아야 한다.
- cost coverage는 0.99/1.00/0.95 gate를 그대로 통과해야 한다.
- PILOT 미달 예외만 가능하며 reason, exact cost evidence, expiry, proposer·approver와 모두 다른
  oversight approver, oversight decision digest가 필요하다. 예외는 trust gate를 바꾸지 않는다.
- UNKNOWN cost, unclosed period, stale close, 일반가용성 미달, 임의 가격/fixture는 fail-closed다.

### 5.4 서면 계약, 계좌이체와 12 capability

`recordCommercialContractPeriod` ORIGINAL은 current qualification, current tariff, 서명된 서면
계약/offer, isolated deployment configuration에 exact하게 묶는다. self-service checkout이나
결제 성공이 계약을 만들지 않는다.

고객 1호의 cash collection은 외부 은행 계좌이체다. 계약 체결, invoice 발행 또는 입금 예상은
cash가 아니다. 외부 은행이 발행한 signed `BANK_TRANSFER` settlement evidence를 exact invoice
fence에 묶어 별도 승인 수명주기로 반입하기 전까지 cash 상태는 `UNKNOWN`이다.

OfferProfile은 다음 12개 entry를 이 순서로 정확히 한 번씩 가진다.

1. `PUBLIC_WEB`
2. `VERIFIED_EMAIL`
3. `API_EXPORT`
4. `SIGNED_WEBHOOK`
5. `DAILY_DIGEST`
6. `WEEKLY_DIGEST`
7. `SMS`
8. `TELEGRAM`
9. `WHATSAPP`
10. `LINE`
11. `KAKAO`
12. `VOICE`

각 entry는 `INCLUDED_REQUIRED` 또는 `NOT_OFFERED`다. 기본 offer template, health 상태, sales
note, UI checkbox는 authority가 아니다. omitted entry를 included나 not-offered로 추론하지
않는다. 포함된 capability는 quota/overage/activation/consent/cost 정책을 exact contract digest에
묶고 production activation evidence를 별도로 충족한다.

### 5.5 Usage → invoice → {revenue | cash | tax}

Hard dependency는 usage에서 invoice까지다. invoice 이후 revenue, cash, tax는 각각 필요한
signed evidence가 도착한 순서로 반입할 수 있는 별도 authority다. 아래 번호는 운영 체크 순서일
뿐, revenue → cash → tax 의존관계를 뜻하지 않으며 셋은 서로를 증명하지 않는다.

1. **Usage:** `recordUsageWindow`로 signed window receipt와 current usage fact를 기록한다.
   `COMPLETE` zero는 진실한 0이지만 `PARTIAL`/`UNKNOWN`은 0이 아니며 자동 charge를 만들지
   못한다. current contract와 tariff, meter policy, half-open window를 exact하게 묶는다.
2. **Invoice:** `recordInvoice`로 header, contiguous ordered line set, 모든 due usage root의
   membership set을 함께 reconcile한다. zero usage/included allowance도 null charge line을 가진
   membership으로 한 번 나타나야 한다. stale tariff, partial/unknown usage, membership gap,
   currency/total mismatch가 하나라도 있으면 전체 invoice를 BLOCKED로 둔다.
3. **Revenue:** `recordRevenue`는 reconciled invoice의 eligible non-adjustment line과 실제
   performance receipt에만 묶는다. tax-exclusive recognizable amount만 사용하고 interval overlap,
   cumulative over-recognition, invoice-issue/payment/import 시각으로의 임의 당겨쓰기를 금지한다.
4. **Cash:** 고객 1호는 `recordCashApplication`에 signed typed external `BANK_TRANSFER` source
   evidence와 exact immutable invoice ID/version/record digest 및 reconciliation digest만 묶는다.
   계약의 `PG_SETTLEMENT` discriminator는 별도 승인된 외부 회계 import가 있을 때만 사용할 수
   있으며 live PG 호출, B2B checkout, payment execution, donation fact, entitlement가 아니다.
   invoice 발행, revenue, elapsed time, unverified provider/webhook 상태에서 cash를 합성하지 않는다.
   증빙이 없으면 `UNKNOWN`이다.
5. **Tax issuance:** `recordTaxInvoiceIssuance`는 외부 전자세금계산서 발행 acknowledgement와
   exact invoice ID/version/digest를 typed import한다. Gurinnae가 ASP를 호출하지 않으며 누락
   acknowledgement는 `UNKNOWN`이다. invoice tax와 발행 확인은 revenue/cash를 증명하지 않는다.

정정이 필요하면 `recordAccountingCorrection` 또는 해당 authority의
REPLACEMENT/REVERSAL을 추가한다. 기존 row나 invoice line을 수정하지 않는다.

## 6. Replay, conflict, ambiguity

| 관측 | 판정 | 운영자 행동 |
| --- | --- | --- |
| 같은 idempotency identity와 같은 request digest | exact replay | 저장된 receipt를 다시 검증하고 새 proposal/job을 만들지 않음 |
| 같은 identity에 다른 digest | idempotency conflict | 즉시 중단하고 두 요청의 source/predecessor 차이를 조사 |
| 같은 execution authorization event | execution replay | 기존 effect receipt를 사용하고 중복 실행하지 않음 |
| in-progress/lease 보유 | 결과 미확정 | 같은 `executionId` receipt를 poll하고 새 전송 금지 |
| stale version/fence/digest | optimistic conflict | current proposal, assignment, authorization, target head를 다시 읽고 새 evidence로 재검토 |
| timeout/queue ack 없음/worker 단절 | ambiguous | 성공·실패로 추정하지 않고 receipt chain과 resulting object head를 reconciliation |
| receipt incomplete 또는 `reconciliationRequired=true` | blocked | downstream tariff/contract/invoice/revenue/cash/tax 진행 중지, 담당자와 기한을 가진 issue 생성 |

자동 retry나 새 idempotency key로 ambiguity를 덮지 않는다. `retryActionExecution`은 exact same
execution에서 no-effect 또는 provider-idempotent replay-safe 증거가 현재 계약을 만족할 때만
별도 운영 검토 후 사용한다.

Ambiguity가 발생하면 운영자는 다음 순서를 따른다.

1. 전송·자동 retry·새 proposal·새 idempotency identity·lease release를 모두 멈춘다.
2. 같은 `executionId`와 generation으로 receipt chain을 조회하고 authorization, attempt, effect
   receipt의 current 상태를 고정한다.
3. exact target root/head와 predecessor/version/digest를 authoritative owner read 경계에서 조회한다.
4. 저장된 request/effect idempotency digest가 동일하면 기존 receipt를 사용하고, 다르면 conflict로
   격리한다. queue ack, timeout, worker log는 no-effect 증거가 아니다.
5. effect receipt와 resulting head가 exact하게 일치하고 terminal success이며
   `reconciliationRequired=false`일 때만 downstream latch를 해제한다.
6. no-effect 또는 replay-safe proof를 독립 검토할 수 없으면 blocked issue를 유지한다. 자동
   resubmit, 자동 success/failure 판정, 자동 unblock은 금지한다.

## 7. Rollback과 reconciliation

여기서 rollback은 기존 경제 row 삭제나 되돌려쓰기라는 뜻이 아니다.

- **실행 전:** stale preview를 폐기하고 proposal을 수정·재preview하거나 reviewer가
  `CHANGES_REQUIRED`/`REJECT`한다. execution이 이미 authorization되었다면 단순 취소를 effect
  없음의 증거로 취급하지 않는다.
- **실행 후:** root, predecessor ID/version/digest를 exact하게 묶은 REPLACEMENT, REVERSAL,
  RESTATEMENT 또는 accounting correction을 새 `ECONOMICS_IMPORT` 승인 수명주기로 추가한다.
- **Cost:** 완전한 superseding PERIOD header와 전체 ordered LINE set을 다시 닫는다. delta-only
  orphan line, 부분 carry-forward, latest-period join을 금지한다.
- **Invoice/revenue:** invoice membership과 line set을 완전 restatement하고, 영향받는 revenue
  interval을 별도 correction/reallocation한다. 과거 source bytes와 과거 cutoff 결과를 보존한다.
- **Cash/tax:** 외부 은행/전자세금계산서 authority에서 먼저 정정·반전 증빙을 받고 해당 typed
  chain을 append한다. Gurinnae 내부 reversal이 외부 settlement/issuance를 취소하지 않는다.
- **Cross-authority:** 한 authority의 correction이 다른 authority를 자동 수정하지 않는다. 영향받은
  authority별 reconciliation issue와 typed correction receipt가 각각 필요하다.

Reconciliation evidence에는 원 receipt, current head, expected/observed digest, 영향받은 authority,
public-access no-effect, owner, backup, due-at, next-review-at를 포함한다. raw payload와 secret은
포함하지 않는다.

## 8. Dunning과 계약 suspension

`recordCollectionFailure`는 `BANK_RETURN_CONFIRMED` signed external failure 또는
`PROVIDER_FETCH_CONFIRMED` authoritative provider fetch failure가 exact invoice/payment-attempt
binding에 묶일 때만 허용한다. cash application이 없다는 사실, due date 추정, missing webhook,
initial charge response, transient error는 collection failure가 아니다.

Collection failure의 자동 effect는 운영자 task와 notification뿐이다. contract status,
capability activation, entitlement, publication, investigation, public access를 바꾸지 않는다.
Private contract suspension이 필요하면 현재 contract root/revision/digest와 failure/task evidence를
묶은 별도 REPLACEMENT contract period를 새 proposal → preview → 독립 review → STEP_UP approve
수명주기로 처리한다. worker가 이를 자동 제안·승인·실행하지 않는다.

## 9. 종료 기준

고객 1호 경제 원장 단계는 다음을 모두 evidence bundle에 남겼을 때만 해당 단계가 완료된다.

- proposal/preview/review/STEP_UP decision/execution authorization/effect receipt chain
- proposer-reviewer 분리, current policy/capability/conflict evidence
- exact target current head와 receipt/result digest 대조
- replay/conflict 결과와 `reconciliationRequired=false`
- qualification은 13 criteria와 role/acquisition binding 검증
- cost close는 actual production source/category/FX/correction evidence와 coverage gate 검증
- tariff는 exact cost-close binding과 P75 margin gate 검증
- contract는 signed written source와 ordered 12 capability set 검증
- usage/invoice/revenue/cash/tax는 각 authority별 receipt와 UNKNOWN/blocked 항목을 별도 표시
- 공개 무료 접근과 editorial/trust firewall fingerprint가 전후 동일함을 확인

TEST fixture PASS, local unit test, migration catalog check는 위 production evidence를 대신하지
않는다. 한 항목이라도 미확정이면 `ARTIFACT_READY`, first customer live, first billing complete,
first cost close complete라고 보고하지 않는다.

## 10. OPEN_QUESTIONS와 미구현 항목

1. **Engineering — role provisioner FINAL:** checksummed pre-provisioning 경로는 존재하지만 final
   `0041` postcondition oracle, manifest/fingerprint 정합성, provision-first integration evidence가
   확정돼야 한다. 그 전에는 역할 SQL/wrapper를 production command로 게시하지 않는다.
2. **Engineering — typed owner pipeline:** current
   [`0041_r6e_monetization_runtime.sql`](../../db/migrations/0041_r6e_monetization_runtime.sql)은
   closed row-valued economics detail의 canonical field equality, exact owner-function dispatch,
   effect receipt까지 독립적으로 증명하지 못한다. generic `jsonb`, nonempty-only validator,
   relation-name dispatch가 남아 있거나 owner/runtime test가 없으면 production importer는 계속
   `UNAVAILABLE`이다.
3. **Engineering — TEST_FIXTURE bootstrap:** final economics fixture는 manual signed typed cost close,
   proposer-reviewer 분리, owner execution, derived digest, replay/conflict, tariff allow/deny와
   ephemeral rollback을 실제로 실행해야 한다. 현재 marker-only fixture를 증거로 사용하지 않는다.
4. **Engineering — cash source fence:** economics owner path는 `BANK_TRANSFER`와
   `PG_SETTLEMENT` 각각에 대해 signed typed external source evidence와 exact invoice
   ID/version/record/reconciliation digest를 검증해야 한다. `PG_SETTLEMENT`가 live PG 호출,
   checkout, payment execution, donation, entitlement 경로를 열지 않는다는 runtime proof 전에는
   production cash import를 실행하지 않는다.
5. **Operator — production invocation:** request-bound Actor Assertion을 발급하고 전체 action lifecycle을
   호출하는 승인된 operator UI/CLI와 final owner-function ABI가 current production artifact에
   배포·검증되어야 한다. 그 전에는 이 문서가 `curl`, SQL, queue injection을 제공하지 않는다.
6. **Operator — production source authority:** qualification, acquisition, cost source/category matrix, FX,
   written contract/offer, usage meter, performance, 고객 1호 `BANK_TRANSFER`,
   전자세금계산서 acknowledgement, collection failure의 실제 source system·서명 형식·retention
   책임자를 운영자가 확정해야 한다.
7. **Operator — 첫 production 수치:** tariff amount, P75 revenue/cost, accounting/tax/cost policy, materiality,
   service interval, capability quota는 fixture나 default template이 아니라 독립 승인된 실제
   evidence로 정해야 한다.
8. **Engineering/Operator — production runtime acceptance:** workflow-worker executor와 전용
   `gurine_economics_importer` credential의 owner-role ACL, SERIALIZABLE owner execution,
   claim/fence/replay/conflict, restart/ambiguity reconciliation, receipt 조회를 실제 deployment에서
   검증해야 한다. billing-gateway credential 재사용이 불가능함도 확인한다. local test는 이를
   대신하지 않는다.
9. **Operator — live provider boundary:** R6e에는 live PG, live ASP, production donation tier, durable billing-key
   vault/egress channel이 없다. 후원은 `TEST_MODE_ONLY`, production action은 `UNAVAILABLE`로
   유지한다. 이를 임의 credential이나 endpoint로 해소하지 않는다.
10. **Operator — dunning authority:** `PROVIDER_FETCH_CONFIRMED`는 exact payment-attempt context,
   `BANK_RETURN_CONFIRMED`는 exact invoice ID/version/record/reconciliation digest에 묶인 signed
   evidence여야 한다. 이 두 source별 형식이 승인되기 전에는 자동 dunning을 시작하지 않는다.
11. **Operator — external DB authentication:** `PASSWORD NULL`인
   `gurine_billing_gateway`와 `gurine_economics_importer`에 client certificate, managed IAM, peer 또는
   동등한 외부 인증을 어떤 배포 권위가 발급·매핑·회전·폐기할지 미정이다. 실제 runtime pool에서
   두 exact `session_user=current_user` 결과를 보존하기 전에는 enabled TEST_ONLY/production을
   `UNAVAILABLE`로 유지한다. URL, password, certificate 경로 또는 signature를 source/runbook에
   발명하지 않는다.
12. **Engineering — billing principal과 runtime store:** current billing-gateway는
   `session_user=current_user=gurine_billing_gateway` startup probe와 PostgreSQL owner-function store의
   실행 증거가 없으며 `TEST_ONLY` runner가 차단돼 있다. FINAL `0041` owner/ACL ABI 뒤에 exact-role
   probe, payment store, worker/runtime wiring, replay와 receipt를 검증하기 전에는 TEST_ONLY도
   availability 근거가 아니다. production은 live payment 경계가 별도로 금지된 상태를 유지한다.
